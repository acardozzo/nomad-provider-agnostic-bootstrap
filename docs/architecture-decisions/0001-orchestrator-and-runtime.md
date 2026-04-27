# ADR 0001 — Orchestrator and Workload Runtime for orbty

**Status:** Proposed (pending validation sprint)
**Date:** 2026-04-27
**Authors:** Ailton Cardozo + Claude (collaborative)

---

## Context

orbty is being built as a **vendor-agnostic alternative to Fly.io and Railway**:
a multi-tenant PaaS where developers push code and orbty runs it.

The first iteration of orbty was prototyped on top of Crossplane + managed
Kubernetes (GKE/EKS/AKS/DOKS/VKE/etc.). That work validated the *control-plane
shape* but locked orbty into the k8s ecosystem and, transitively, into whichever
managed-k8s offering each cloud sells. The vendor-agnostic goal is incompatible
with that.

The repository this ADR lives in (`nomad-provider-agnostic-bootstrap`) was a
**5-day proof-of-concept**: can we provision a complete orchestration platform
on raw VMs from any cloud (Vultr, Linode, Hetzner, bare metal), bootstrapped
purely from Terraform + Ansible, with no managed-k8s dependency?

The PoC succeeded:

- Multi-provider Terraform (Vultr + Linode, mocked tests in CI)
- 5-VM Multipass replica that mirrors the production topology
- Consul + Nomad cluster with ACL bootstrap, gossip encryption
- Traefik v3 ingress with Let's Encrypt staging certs issued via Cloudflare
  DNS-01 (verified live)
- Smoke tests covering ACL, ingress, TLS
- Hardening (UFW, fail2ban, unattended-upgrades), backups, monitoring,
  autoscaling roles all in place

That stack is the candidate base for the next iteration of orbty.

## Forces

1. **Multi-tenant isolation** — paying customers run untrusted code beside
   each other. Container-namespace isolation alone is below the bar customers
   expect from a PaaS.
2. **Cold start** — Fly's pitch hinges on ~125 ms boots. Anything slower than
   ~500 ms positions us against Railway, not Fly.
3. **Density / margin** — runtime overhead per tenant directly determines
   gross margin.
4. **Operational burden on a small team** — every layer that has to be
   self-operated is a layer that takes people away from product.
5. **Vendor lock-in** — orbty's positioning explicitly rejects single-cloud
   dependency.
6. **Hiring pool / market expectation** — some customers ask "is it k8s
   underneath?" and price the answer into trust.
7. **Existing investment** — 5 days of working Nomad bootstrap is sunk capital
   we should leverage, not discard.

## Options Considered

### A. Nomad + Docker (status quo of the PoC)

- **Density:** high. **Isolation:** namespaces only. **Velocity:** zero
  additional work — already running.
- **Verdict:** good fit for a *trusted-tenant* PaaS (Coolify/Dokploy/CapRover
  niche), inadequate for a Fly competitor.

### B. Nomad + Firecracker (chosen)

- **Density:** medium (~5 MB Firecracker VMM + tenant rootfs).
- **Isolation:** hardware-level (KVM).
- **Velocity:** estimated 2–3 months to production-grade; community
  `firecracker-task-driver` exists but is not as battle-tested as the Docker
  driver.
- **Verdict:** matches the product positioning exactly. The same architecture
  Fly arrived at, reached via a higher-level orchestrator instead of a custom
  one.

### C. Kubernetes + Kata Containers

- **Density:** medium. **Isolation:** hardware-level. **Velocity:** k8s
  self-hosted *plus* Kata is an enormous operational surface.
- **Verdict:** rejected. Worst of both worlds for a small team.

### D. Custom orchestrator (flyd-style)

- **Velocity:** 2+ years. Fly has 50+ engineers and still ships carefully.
- **Verdict:** rejected. Out of scope for this team size.

## Decision

orbty will be built on **Nomad as the orchestrator** and **Firecracker as the
tenant workload runtime**. System-level workloads (Traefik, Postgres, Vault,
Loki, etc.) continue to run as Docker tasks on Nomad. Tenant workloads run as
Firecracker microVMs scheduled by Nomad.

This decision is **gated by a validation sprint** (see Consequences) that must
hit specific cold-start, RAM, and density numbers before the wider port
proceeds. If the sprint fails, this ADR is superseded.

## Why not Kubernetes

- **Vendor lock-in by another name.** Even self-hosted, the k8s API binds us
  to its ecosystem cadence (CNI, CSI, CRD upgrades, security advisories, kubelet
  upgrades). Switching cloud providers is easy; switching off k8s once you're
  in is not.
- **Operational footprint.** A 3-server Nomad+Consul control plane runs in
  ~600 MB RAM. A 3-node k3s control plane is ~6 GB. At our scale, that ratio
  compounds across every region.
- **Ecosystem we'd actually use is portable.** The k8s features we wanted
  (Loki, Tempo, Alertmanager, Vault, MinIO) all run as Nomad jobs from the same
  Docker images — no operator required. The k8s features we *can't* easily
  port (Cilium, Velero, ESO, Argo Rollouts, KEDA) are all replaceable with
  simpler Nomad-native equivalents (Consul Connect, restic, Vault, Nomad
  canary, Nomad Autoscaler).

## Why not flyd

- It's a 50-engineer-year build. We need to ship in months, not years.

## Why not stay on Docker

- Docker's tenant boundary is `seccomp` + `AppArmor` + cgroups. Real-world
  container escapes happen often enough to make this a no-go for a
  paying-customers-with-credit-cards product.

## Consequences

### What this enables

- Single product story: "orbty runs your app as a microVM on whatever cloud
  you point us at, no k8s required."
- Re-use of the existing Nomad bootstrap as the foundation. The Layer-0/1
  work in this repo (Terraform multi-provider, Ansible roles, Consul/Nomad/
  Traefik, smoke tests, CI) carries forward unchanged.
- Capability ports already mapped (logs, alerts, traces, secrets, mesh,
  storage, DB, queue, registry, IAM) all remain Nomad-native and proceed in
  the order defined by the audit.

### What this closes

- **Crossplane is no longer the orbty control plane.** The orbty-platform
  Crossplane work moves to a separate concern (operating *managed* k8s for
  customers who explicitly ask for k8s tier), or is retired entirely.
- **K8s ecosystem features that can't be ported simply (Velero, Cilium, ESO,
  KEDA, Karpenter, Argo Rollouts) are explicitly out of scope.** We will
  document the Nomad-native equivalent we ship instead, and accept the gap.

### Validation sprint (gating this ADR)

A 1-sprint (~16 h) experiment must pass before the wider port begins. Spec to
be written at:
`docs/superpowers/specs/2026-04-27-nomad-firecracker-validation-sprint.md`

The sprint subjects a single Nomad client to the `firecracker-task-driver`
and measures:

| Metric | Target | Rationale |
|---|---|---|
| Tenant cold start (no rootfs cache) | < 500 ms | Below this we lose vs Fly |
| Tenant cold start (warm rootfs cache) | < 200 ms | Within shouting distance of Fly's 125 ms |
| RAM overhead per idle microVM | < 50 MB | Density math for pricing |
| microVMs per 2 GB Nomad client | ≥ 20 | Same |
| Outbound network per microVM | working through Traefik catalog tags | Confirms the ingress path doesn't change |
| Lifecycle: create / restart / destroy via Nomad CLI | clean | Driver maturity check |

If two or more targets miss, the ADR is revisited before any production
commitment.

### Reversal criteria

This decision should be re-evaluated if any of the following occur:

1. **Validation sprint fails on ≥2 metrics** above.
2. **Firecracker driver project is abandoned** (no commits for 6 months,
   maintainer departure with no successor).
3. **Major security CVE in Firecracker** that AWS does not patch within 30
   days (AWS owns Firecracker upstream).
4. **Customer demand for k8s-native APIs** (Helm chart deploy, kubectl
   access) becomes the dominant feature ask, justifying a parallel k8s tier.
5. **Team grows past ~15 engineers** and we can afford to operate a custom
   orchestrator (flyd-style).

## Scope — Known Gaps Accepted

The audit (and its 2026-04-27 operator-level addendum) confirms that
**23 of 26** orbty-platform capabilities port cleanly to Nomad+Firecracker.
Three are known limitations we accept:

1. **HTTP-driven scale-to-zero** (Knative / KEDA HTTP add-on) — Nomad
   Autoscaler scales on metrics, not on request arrival. Workaround until
   it becomes blocking: keep one warm replica per tenant; revisit only if a
   tenant explicitly demands zero-cost-when-idle pricing.
2. **Cloudflare Workers / R2 / D1 / KV / Queues** (capability #20) — these
   are Cloudflare products, not infrastructure portable to any cloud. orbty
   integrates them at the application layer via API; they are not part of
   what self-hosted orbty provisions.
3. **ArgoCD continuous reconciliation** (capability #16) — replaced by
   Atlantis (PR-driven Terraform). Functionally covers GitOps but with
   discrete apply rather than continuous reconciliation. If continuous
   drift correction becomes critical, revisit.

The two capabilities **added by the 2026-04-27 addendum** (Tailscale admin
overlay #25, continuous security scanning #26) are net-new work for this
stack and enter the roadmap as MEDIUM-severity items, not blockers for the
validation sprint.

The two operators **sub-mapped** in the original audit:

- **External Secrets Operator** — covered by `consul-template` sidecar +
  Vault, not a missing capability
- **Kyverno admission control** — partial coverage via OPA + CI pre-apply
  gates; full admission webhook semantics is not portable to Nomad without
  Enterprise Sentinel

## References

- Audit: `docs/audits/2026-04-27-orbty-crossplane-vs-nomad-bootstrap-audit.md`
- PoC outcome: this repository as of commit `ed836bc` (last security-fix
  commit on `main`)
- Firecracker: https://firecracker-microvm.github.io/
- Nomad firecracker-task-driver:
  https://github.com/cneira/firecracker-task-driver
- Fly's architecture writeup:
  https://fly.io/blog/fly-machines/
- Why we're not k8s (this is precedent, not gospel):
  https://www.hashicorp.com/blog/nomad-vs-kubernetes
