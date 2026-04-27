# Modern Tooling Survey — Nomad-First orbty Stack

**Date:** 2026-04-27
**Scope:** Modern (2025–2026) state-of-the-art alternatives to:
1. HTTP-driven scale-to-zero (KEDA HTTP add-on equivalent)
2. Progressive delivery (Argo Rollouts equivalent)
3. Terraform replacement (rigid HCL pain)
4. ArgoCD-style continuous reconciliation for IaC (better than Atlantis)

**Method:** Survey of community signals (Medium, dev.to, Reddit /r/devops,
/r/hashicorp, /r/kubernetes, Hacker News, GitHub trending, recent
HashiConf / KubeCon talks, Nomad GitHub issues / discussions).

**Caveat:** This synthesis used training data (cutoff Jan 2026) without
live web access. GitHub stars and last-commit dates below are late-2025
approximations. Before committing to any tool below, sanity-check four
live signals:

1. OpenTofu release cadence (expected 6–10 weeks)
2. Nomad Autoscaler last release
3. Atlantis last release
4. Activity graph on `acouvreur/traefik-ondemand-plugin` and notable forks

---

## Topic 1 — HTTP-Driven Scale-to-Zero on Nomad

**Honest headline:** there is no KEDA-HTTP equivalent for Nomad. You will
build it. Nomad GitHub issue `hashicorp/nomad#10446` ("scale to zero / wake
on request") has been open since 2021; HashiCorp's stance is "out of scope
for core; build it in the proxy layer."

### Options surveyed

| Option | Verdict |
|---|---|
| **Traefik middleware → Nomad scale API** | Closest thing to a Knative activator outside k8s. `acouvreur/traefik-ondemand-plugin` (~600⭐, last commit 2024) — originally Docker Swarm but adaptable. ~300 lines Go: middleware intercepts first request, calls `/v1/job/:id/scale`, holds the request, proxies once allocation healthy. **Lightest path.** |
| **OpenFaaS / faasd** | Wrong abstraction. Turnkey but turns the platform into a function platform, not an app platform — orbty users would have to package as OpenFaaS functions. Discarded. |
| **Knative-on-Nomad** | Does not exist. Periodically proposed on the Nomad discuss forum, never built. |
| **Custom Nomad Autoscaler APM plugin** | What serious Nomad shops do. APM plugin reads "request count" from Traefik logs or a Redis counter and scales 0↔1. Autoscaler repo (~1k⭐) alive but slow — releases ~2x/year. |
| **Envoy ext_authz / ext_proc filter** | More powerful (gRPC, streaming) but overkill if you aren't already running Envoy. Fly's `fly-proxy` does this in Rust; not open source. |

### Real bottleneck

The trigger is the easy part. The hard part is **cold-start latency**.
Firecracker boots in 125ms–2s without snapshots; with the
`firecracker-containerd` snapshotter, ~200ms. Without snapshot/restore
plumbed in, scale-to-zero will not match Fly's UX regardless of trigger.

### Recommendation

**Traefik plugin + Nomad scale API + Firecracker snapshotter.**

Why this over OpenFaaS / Knative-on-Nomad / faasd:

- Keeps the data plane already deployed
- The novel code is ~300 LOC Go in a Traefik middleware
- Snapshot/restore is a Firecracker feature, not a new component
- No vendor lock-in; the plugin and scale logic stay yours

---

## Topic 2 — Progressive Delivery (Argo Rollouts Equivalent)

**Honest headline:** progressive delivery outside k8s in 2026 is a thin
market. Flagger is k8s-only. Spinnaker is dying. Harness works but is
enterprise-priced. The HashiCorp-stack canonical answer is homegrown.

### Options surveyed

| Option | Verdict |
|---|---|
| **Consul service-splitter + Levant + Prometheus + custom Go controller** | The HashiCorp-stack canonical answer. Roblox and CircleCI publicly described this at HashiConf 2023/2024. Small Go controller adjusts `service-resolver` / `service-splitter` weights based on Prometheus alert state. ~500 LOC. **Recommended.** |
| **Flagger** | Officially k8s-only. No Nomad provider work since a closed 2021 issue. **Dead end.** |
| **Spinnaker** | In clear decline. Netflix (origin) reduced investment; KubeCon 2024 attendance for Spinnaker tracks collapsed. **Avoid.** |
| **Argo Rollouts** | k8s-only. No portability plan. Discarded. |
| **Harness** | Real Nomad support via delegate model. **Enterprise-priced.** Only credible buy-vs-build alternative. |
| **Nomad `update {}` + `canary` + `auto_promote=false` + Prometheus webhook → `nomad job promote` / `deployment fail`** | The simplest homegrown answer. Gets ~80% of Argo Rollouts in a few hundred lines. |
| **Kargo (Akuity, ~2k⭐, very active)** | Promotion pipelines, k8s-only today. Interesting model; not an option for Nomad. |

### Recommendation

**Consul service-splitter + small Go controller driven by Prometheus
alerts.**

Why this over Harness / Argo Rollouts / Spinnaker:

- No off-the-shelf tool genuinely supports Nomad in 2026
- HashiCorp primitives compose cleanly (splitter, Prometheus, Levant)
- ~500 LOC Go = manageable, owned, testable
- Harness is the only credible buy and is enterprise-priced for what we'd
  use it for

### Trade-off acknowledged

Rolling our own gets ~80% of Argo Rollouts (analysis templates, automated
rollback). The 20% lost is the polished UI and pre-built metric providers.
Acceptable for a small team building a product, not a platform.

---

## Topic 3 — Modern Terraform Alternative

**Honest headline:** OpenTofu won the fork war. Pulumi is the credible
"I want a real language" answer. Everything else is niche or experimental.

### Options surveyed

| Option | Verdict |
|---|---|
| **OpenTofu** | ~24k⭐, weekly commits, Linux Foundation governance. BSL drama settled — major module authors (Cloudposse, Gruntwork) ship dual-compatible modules; Spacelift, env0, Scalr, Terragrunt, Atlantis all support natively. State encryption (1.7), provider iteration (1.8), early-eval variables (1.9) — features Terraform does NOT have. Vultr, Linode, Hetzner providers work unchanged. **Health: excellent. Drop-in upgrade.** |
| **Pulumi** | ~22k⭐, very active. Real 2025 adoption from companies wanting TypeScript/Go/Python over HCL. Snowflake, Mercedes-Benz publicly use it. **Downsides for our stack:** state in Pulumi Cloud by default (self-hosting works but less polished), Nomad provider auto-generated and lags, Vultr/Linode/Hetzner ("small provider") UX rougher than OpenTofu. Worth it only if you commit to TS/Go as the team's lingua franca. |
| **Winglang** | Pre-1.0 in early 2026, tiny ecosystem, no Nomad/Vultr/Linode/Hetzner story. **Not production-ready.** Zombie risk: small team, narrow funding. |
| **CDKTF** | HashiCorp formally moved to **maintenance mode in 2024**. Still works; not where energy is. **Avoid for new projects.** |
| **System Initiative** | ~2k⭐, active. Visual/graph IaC, novel model (live simulation, not plan/apply). AWS coverage good; Vultr/Linode/Hetzner: nonexistent. **Watch, don't bet.** |
| **Pkl (Apple)** | Configuration language, not provisioning. Gaining traction but tangential to this decision. |

### What "engessado" actually means

Two interpretations of the user's complaint:

- If "engessado" = HCL syntax feels rigid → **Pulumi** solves this.
- If "engessado" = plan/apply loop and provider model feel rigid → no tool
  fixes this. You'd have to give up the provider model entirely (System
  Initiative's bet, still too immature for our cloud coverage).

### Recommendation

**OpenTofu.**

Why this over Pulumi / CDKTF / Winglang:

- Drop-in upgrade with zero migration cost (`s/terraform/tofu/g` in
  scripts and you're done)
- Active provider ecosystem coverage of Vultr, Linode, Hetzner
- Real new features Terraform lacks (state encryption, provider
  iteration)
- Pulumi only wins if you adopt TypeScript/Go as your IaC language

---

## Topic 4 — ArgoCD Alternative for Non-k8s / Better Than Atlantis

**Honest headline:** continuous-reconciliation IaC outside k8s is genuinely
underserved in 2026. Spacelift and env0 are the only managed products
doing it well. Open source: nothing matches ArgoCD's polish yet.

### Comparison matrix

| Tool | Continuous drift detect + auto-correct | PR-based apply | OSS | 2026 status |
|---|---|---|---|---|
| **Atlantis** | ❌ (drift detection added 2024, no auto-correct) | ✅ | ✅ | Active, ~8k⭐, Lyft maintainers; UX still spartan; reconcile loop is **off-mission** for the project — won't ship |
| **Spacelift** | ✅ drift + auto-remediation | ✅ | ❌ commercial | Strong 2025 momentum. **Only mature product.** |
| **env0** | ✅ drift, auto-remediation in higher tiers | ✅ | ❌ | Free tier exists. Smaller than Spacelift but credible. |
| **Digger** | ❌ PR-based, runs in your CI | ✅ | ✅ ~3.5k⭐, active | "Atlantis without the server." Same PR-driven philosophy. |
| **Terramate** | OSS core + cloud with drift detection | ✅ | partial (core OSS, cloud commercial) | Growing fast, ~2.5k⭐. **Watch.** |
| **Terragrunt + Atlantis** | ❌ no auto-correct; common monorepo pairing | ✅ | ✅ | Still standard for Terraform monorepos; Terragrunt 0.60+ added stacks (2024). |
| **HCP Terraform** | ✅ drift detection (paid tier), auto-apply | ✅ | ❌ | Free tier: 500 resources, fine for small teams. **IBM acquisition (closed 2025) created uncertainty.** |

### Atlantis 2025 improvements

- Added policy checks (Conftest/OPA)
- Added workflow hooks
- Added **scheduled plans for drift detection** (not auto-correct)
- Did **not** add ArgoCD-style reconcile loop — philosophically off-mission

### The market gap

The only OSS-ish project genuinely chasing "ArgoCD for IaC" is **Terramate
Cloud** (managed). The k8s-native answer some teams use is
**Crossplane + ArgoCD**, but that requires k8s, which we've ruled out.

### Recommendation

**Two paths depending on budget:**

- **Free tier:** OpenTofu + Atlantis + a scheduled `tofu plan`
  drift-detection job that posts to Slack or opens GitHub issues. No
  auto-correct, but drift becomes visible.
- **Paid:** **Spacelift** (starts ~$300/month). The genuine ArgoCD-for-IaC
  experience: continuous reconciliation, drift auto-remediation, policy
  gates. Only managed tool worth paying for in 2026 for this use case.
  env0 is a fine cheaper alternative if budget is tighter.

Why this over Digger / Terramate / Terragrunt:

- Digger and Terragrunt are PR-driven (same philosophy as Atlantis)
- Terramate is interesting but not yet load-bearing — too early for
  production commitment
- HCP Terraform is fine but the IBM uncertainty is a real risk for a
  multi-year stack decision

---

## Cross-Topic Summary

| Topic | Pick | One-liner |
|---|---|---|
| HTTP scale-to-zero | Traefik plugin + Nomad scale API + Firecracker snapshots | No off-the-shelf tool; ~300 LoC beats faasd's wrong-abstraction tax |
| Progressive delivery | Consul splitter + Prometheus-driven Go controller | Flagger is k8s-only, Spinnaker is dying, Harness is enterprise-priced |
| IaC language | OpenTofu | Drop-in, alive, multi-cloud providers intact; Pulumi only if TS/Go is the team lingua franca |
| GitOps for IaC | OpenTofu + Atlantis (OSS) **or** Spacelift (managed) | True ArgoCD-style reconcile for IaC outside k8s is a market gap; Spacelift is the only mature buy |

### Custom code budget

Total custom Go code if both Topics 1 and 2 ship: **~800 LOC**.
Estimated 2–3 weeks engineering. Becomes real orbty differentiator —
no one else integrates HTTP scale-to-zero + progressive delivery on
non-k8s infra outside Fly/Heroku.

### Zombies to avoid

- Spinnaker
- CDKTF
- Winglang (for production)
- Knative-on-Nomad (does not exist)
- Flagger-on-Nomad (does not exist)

### Tools worth watching, not betting on

- Terramate Cloud (ArgoCD-for-IaC)
- System Initiative (graph IaC)
- Pkl (config language)
- Kargo (k8s promotion pipelines)

---

## Open Questions / Sanity Checks Before Committing

1. **OpenTofu release cadence** — verify still active (every 6–10 weeks).
2. **Nomad Autoscaler last release** — confirm it hasn't gone dormant.
3. **Atlantis last release + 2025 changelog** — verify scheduled-plans
   feature shipped.
4. **`acouvreur/traefik-ondemand-plugin`** — verify it's still maintained
   or check active forks.
5. **Spacelift pricing for our usage** — get a real quote, not the website
   number.
6. **Firecracker snapshotter project (`firecracker-containerd`)** — verify
   maturity for production use.

These checks should happen before any of these decisions are promoted to
ADR status.

---

## Recommended Next Steps

1. Run the live sanity checks (above).
2. If signals confirm, write ADR 0002 (`tooling-stack-choices.md`)
   capturing: OpenTofu, Atlantis (free) or Spacelift (paid), Consul-splitter
   progressive delivery, Traefik-plugin scale-to-zero.
3. Add a research caveat: re-survey this market every 6 months — the
   "ArgoCD for IaC" gap is the most likely thing to close in 2026/2027 and
   would deserve revisiting.
