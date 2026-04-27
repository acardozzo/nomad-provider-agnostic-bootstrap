# Backlog Plan Index — orbty Capability Closure

This index lists every backlog plan needed to close the gaps between this
nomad-bootstrap stack and orbty-platform's full feature set, per the audit
in `docs/audits/2026-04-27-orbty-crossplane-vs-nomad-bootstrap-audit.md`
and the tooling research in
`docs/research/2026-04-27-modern-tooling-survey.md`.

Plans **already written** are linked. Plans not yet written are listed
with their target capability number, expected scope, and proposed file
name. The order reflects ROI ranking — earlier items have the highest
impact-per-effort and should usually be executed first.

---

## Tier 1 — HIGH severity (audit) + LOW effort

| # | Plan | Audit cap. | Effort | Status |
|---|---|---|---|---|
| 1 | [Consul Connect (mTLS mesh)](./_BACKLOG_2026-04-27-consul-connect-mesh.md) | #17 | ~1h | ✅ written |
| 2 | [Observability — logs (Loki + Promtail)](./_BACKLOG_2026-04-27-observability-logs-loki-promtail.md) | #13b | ~4h | ✅ written |
| 3 | [Observability — alerts (Alertmanager + baseline rules)](./_BACKLOG_2026-04-27-observability-alerts-alertmanager.md) | #13d | ~4h | ✅ written |
| 4 | [Backup off-site (restic + nomad snapshots)](./_BACKLOG_2026-04-27-backup-offsite-restic.md) | #19 | ~3h | ✅ written |

---

## Tier 2 — Tooling decisions / strategic enablers

| # | Plan | Source | Effort | Status |
|---|---|---|---|---|
| 5 | [OpenTofu migration](./_BACKLOG_2026-04-27-opentofu-migration.md) | Research §Topic 3 | ~2h | ✅ written |
| 6 | _BACKLOG_2026-04-27-firecracker-validation-sprint.md | ADR 0001 gate | ~16h | ⏳ not written |
| 7 | _BACKLOG_2026-04-27-traefik-scale-to-zero-plugin.md | Research §Topic 1 | ~24h (~300 LOC Go) | ⏳ not written |
| 8 | _BACKLOG_2026-04-27-progressive-delivery-controller.md | Research §Topic 2 | ~32h (~500 LOC Go) | ⏳ not written |
| 9 | _BACKLOG_2026-04-27-gitops-atlantis-with-drift-cron.md | Research §Topic 4 (free path) | ~6h | ⏳ not written |

---

## Tier 3 — Audit MEDIUM severity / MEDIUM effort

| # | Plan | Audit cap. | Effort | Status |
|---|---|---|---|---|
| 10 | _BACKLOG_2026-04-27-observability-traces-tempo-otel.md | #13c | ~6h | ⏳ not written |
| 11 | _BACKLOG_2026-04-27-dns-automation-cloudflare-tf.md | #4 | ~3h | ⏳ not written |
| 12 | _BACKLOG_2026-04-27-vault-nomad-job-with-consul-template.md | #11 | ~10h | ⏳ not written |
| 13 | _BACKLOG_2026-04-27-tailscale-admin-overlay.md | #25 | ~3h | ⏳ not written |
| 14 | _BACKLOG_2026-04-27-trivy-continuous-scanning.md | #26 | ~4h | ⏳ not written |

---

## Tier 4 — Storage & data plane

| # | Plan | Audit cap. | Effort | Status |
|---|---|---|---|---|
| 15 | _BACKLOG_2026-04-27-object-storage-minio-tf-modules.md | #7 | ~6h | ⏳ not written |
| 16 | _BACKLOG_2026-04-27-block-storage-cloud-attach.md | #8 | ~5h | ⏳ not written |
| 17 | _BACKLOG_2026-04-27-postgres-patroni-cluster.md | #9 | ~16h | ⏳ not written |
| 18 | _BACKLOG_2026-04-27-queues-nats-redis-rabbitmq.md | #10 | ~8h | ⏳ not written |
| 19 | _BACKLOG_2026-04-27-container-registry-self-hosted.md | #14 | ~5h | ⏳ not written |
| 20 | _BACKLOG_2026-04-27-image-building-kaniko-buildkit.md | #15 | ~8h | ⏳ not written |

---

## Tier 5 — Identity, multi-tenancy, FinOps, provider breadth

| # | Plan | Audit cap. | Effort | Status |
|---|---|---|---|---|
| 21 | _BACKLOG_2026-04-27-workload-identity-vault-auth.md | #12 | ~10h | ⏳ not written |
| 22 | _BACKLOG_2026-04-27-multi-tenancy-nomad-namespaces.md | #21 | ~16h | ⏳ not written |
| 23 | _BACKLOG_2026-04-27-finops-cost-exporters.md | #18 | ~6h | ⏳ not written |
| 24 | _BACKLOG_2026-04-27-provider-hetzner-tf-module.md | #1 | ~4h | ⏳ not written |
| 25 | _BACKLOG_2026-04-27-provider-do-tf-module.md | #1 | ~4h | ⏳ not written |

---

## Out of scope (intentional gaps, no plans)

These are documented in ADR 0001 ("Scope — Known Gaps Accepted"):

- **HTTP-driven scale-to-zero** at the abstraction level of KEDA HTTP add-on
  (warm-replica workaround instead; see plan #7 for partial coverage).
- **Cloudflare Workers / R2 / D1 / KV / Queues** (capability #20) — not
  portable, integrated as application-layer feature only.
- **ArgoCD continuous reconciliation for IaC** (capability #16) — replaced
  by Atlantis (plan #9); revisit if Spacelift becomes affordable.

---

## Execution recommendation

For each tier, execute in order. Within a tier, plans are reasonably
independent and can run in parallel (different operators on different
worktrees).

When ready to write a not-yet-written plan, invoke
`/superpowers:writing-plans` with the specific filename from the table
above as context. Each plan should follow the same shape as the four Tier-1
plans (TDD with smoke tests, bite-sized steps, no placeholders).

---

## Status legend

- ✅ written — plan exists at the linked path, ready to execute
- ⏳ not written — placeholder; create when scheduled

The total effort to close everything in Tier 1–5 (excluding out-of-scope
items) is approximately **220 hours**, or ~6 weeks of full-time engineering
for one person.
