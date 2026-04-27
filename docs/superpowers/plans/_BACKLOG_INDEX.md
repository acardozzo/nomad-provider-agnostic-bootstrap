# Backlog Plan Index — orbty Capability Closure

This index lists every backlog plan needed to close the gaps between this
nomad-bootstrap stack and orbty-platform's full feature set, per the audit
in `docs/audits/2026-04-27-orbty-crossplane-vs-nomad-bootstrap-audit.md`
and the tooling research in
`docs/research/2026-04-27-modern-tooling-survey.md`.

## Two views

- **Filename tags** (`_BACKLOG_HIGH_*`, `_BACKLOG_ESTRATEGICOS_*`, etc.)
  reflect *what kind of work* the plan is — severity / domain. They group
  plans for understanding.
- **Execution lanes** (A/B/C/D/E below) reflect *how to ship* the plans in
  parallel — dependencies are kept inside a single lane so lanes never
  block each other.

The 5 lanes are not the same as the 5 tier groups: they're rebalanced so
every dep chain stays intra-lane.

---

## Execution: 5 self-contained lanes (zero cross-lane blocking)

### Lane A — Observability stack (5 plans, ~32h wallclock)

```
[logs] ──┬─► [traces]      logs must complete first (Loki datasource)
         └─► [trivy]       logs must complete first (Loki stream sink)
[alerts]                   independent
[progressive-delivery]     independent (queries Prometheus only)
```

| Order | Plan | h |
|---|---|---|
| 1 (parallel start) | [observability-logs](./_BACKLOG_HIGH_2026-04-27-observability-logs-loki-promtail.md) | 4 |
| 1 (parallel start) | [observability-alerts](./_BACKLOG_HIGH_2026-04-27-observability-alerts-alertmanager.md) | 4 |
| 1 (parallel start) | [progressive-delivery-controller](./_BACKLOG_ESTRATEGICOS_2026-04-27-progressive-delivery-controller.md) | 32 |
| 2 (after logs) | [observability-traces](./_BACKLOG_MEDIUM_2026-04-27-observability-traces-tempo-otel.md) | 6 |
| 2 (after logs) | [trivy-continuous-scanning](./_BACKLOG_MEDIUM_2026-04-27-trivy-continuous-scanning.md) | 4 |

**Lane A wallclock:** max(4+6, 4+4, 4, 32) = **32h** (dominated by progressive-delivery).

---

### Lane B — Storage + data plane (5 plans, ~19h wallclock)

```
[minio] ─► [registry] ─► [image-build]
[block]                  independent
[queues]                 independent
```

| Order | Plan | h |
|---|---|---|
| 1 | [object-storage-minio](./_BACKLOG_DATA_2026-04-27-object-storage-minio-tf-modules.md) | 6 |
| 1 (parallel) | [block-storage-cloud-attach](./_BACKLOG_DATA_2026-04-27-block-storage-cloud-attach.md) | 5 |
| 1 (parallel) | [queues-nats-redis-rabbitmq](./_BACKLOG_DATA_2026-04-27-queues-nats-redis-rabbitmq.md) | 8 |
| 2 (after minio) | [container-registry-self-hosted](./_BACKLOG_DATA_2026-04-27-container-registry-self-hosted.md) | 5 |
| 3 (after registry) | [image-building-kaniko-buildkit](./_BACKLOG_DATA_2026-04-27-image-building-kaniko-buildkit.md) | 8 |

**Lane B wallclock:** 6 + 5 + 8 = **19h** (the chain dominates parallel slots).

---

### Lane C — Identity + Tenancy (5 plans, ~22h wallclock)

```
[vault] ─► [workload-identity]
[multi-tenancy] ─► [finops]      (soft dep, same lane to keep clean)
[tailscale]                       independent
```

| Order | Plan | h |
|---|---|---|
| 1 (parallel start) | [vault-nomad-job-with-consul-template](./_BACKLOG_MEDIUM_2026-04-27-vault-nomad-job-with-consul-template.md) | 10 |
| 1 (parallel start) | [multi-tenancy-nomad-namespaces](./_BACKLOG_PLATFORM_2026-04-27-multi-tenancy-nomad-namespaces.md) | 16 |
| 1 (parallel start) | [tailscale-admin-overlay](./_BACKLOG_MEDIUM_2026-04-27-tailscale-admin-overlay.md) | 3 |
| 2 (after vault) | [workload-identity-vault-auth](./_BACKLOG_PLATFORM_2026-04-27-workload-identity-vault-auth.md) | 10 |
| 2 (after multi-tenancy) | [finops-cost-exporters](./_BACKLOG_PLATFORM_2026-04-27-finops-cost-exporters.md) | 6 |

**Lane C wallclock:** max(10+10, 16+6, 3) = **22h**.

---

### Lane D — IaC + GitOps (5 plans, ~8h wallclock)

```
[opentofu] ─┬─► [atlantis]
            ├─► [provider-hetzner]   (weak dep — works on TF too, but kept here)
            └─► [provider-do]        (weak dep — same)
[dns]                                 independent TF module
```

| Order | Plan | h |
|---|---|---|
| 1 | [opentofu-migration](./_BACKLOG_ESTRATEGICOS_2026-04-27-opentofu-migration.md) | 2 |
| 1 (parallel) | [dns-automation-cloudflare-tf](./_BACKLOG_MEDIUM_2026-04-27-dns-automation-cloudflare-tf.md) | 3 |
| 2 (after tofu) | [gitops-atlantis-with-drift-cron](./_BACKLOG_ESTRATEGICOS_2026-04-27-gitops-atlantis-with-drift-cron.md) | 6 |
| 2 (after tofu) | [provider-hetzner-tf-module](./_BACKLOG_PLATFORM_2026-04-27-provider-hetzner-tf-module.md) | 4 |
| 2 (after tofu) | [provider-do-tf-module](./_BACKLOG_PLATFORM_2026-04-27-provider-do-tf-module.md) | 4 |

**Lane D wallclock:** 2 + max(6, 4, 4) = **8h**.

---

### Lane E — Cluster core + strategic Go (5 plans, ~24h wallclock)

```
[backup] ─► [postgres]              soft dep (DR posture for DB)
[consul-connect]                    independent
[firecracker-validation-sprint]     independent
[traefik-scale-to-zero-plugin]      independent
```

| Order | Plan | h |
|---|---|---|
| 1 (parallel start) | [consul-connect-mesh](./_BACKLOG_HIGH_2026-04-27-consul-connect-mesh.md) | 1 |
| 1 (parallel start) | [backup-offsite-restic](./_BACKLOG_HIGH_2026-04-27-backup-offsite-restic.md) | 3 |
| 1 (parallel start) | [firecracker-validation-sprint](./_BACKLOG_ESTRATEGICOS_2026-04-27-firecracker-validation-sprint.md) | 16 |
| 1 (parallel start) | [traefik-scale-to-zero-plugin](./_BACKLOG_ESTRATEGICOS_2026-04-27-traefik-scale-to-zero-plugin.md) | 24 |
| 2 (after backup) | [postgres-patroni-cluster](./_BACKLOG_DATA_2026-04-27-postgres-patroni-cluster.md) | 16 |

**Lane E wallclock:** max(1, 3+16, 16, 24) = **24h** (dominated by scale-to-zero).

---

## Wallclock summary

| Lane | Plans | Wallclock |
|---|---|---|
| A — Observability | 5 | 32h |
| B — Storage + Data | 5 | 19h |
| C — Identity + Tenancy | 5 | 22h |
| D — IaC + GitOps | 5 | 8h |
| E — Cluster Core + Strategic | 5 | 24h |
| **Overall (max of lanes)** | **25** | **32h** |

vs serial 220h → **6.9× speedup with 5 worktrees**.

The bottleneck is Lane A (progressive-delivery-controller alone is 32h
because it's ~500 LOC of Go with full TDD). If wallclock matters more than
clean grouping, swap progressive-delivery into Lane B (where Lane B has
slack: 19h actual). Lane A then drops to max(4+6, 4+4, 4) = 10h, and Lane
B grows to max(19, 32) = 32h. Same overall, but redistribution is possible.

---

## Worktree topology

```bash
# One worktree per lane (5 total)
for lane in A B C D E; do
  git worktree add -b "lane/$lane" "../wt-lane-$lane"
done
```

Inside each lane worktree, dispatch agents per plan in dep order. The
agent for a Stage-2 plan (e.g. traces in Lane A) waits for the Stage-1
plan (logs) to merge into `lane/A` first, then rebases.

When all 5 lanes are green:
```bash
# Sequential merge into main, in any lane order — they don't conflict
for lane in D B E C A; do  # shortest first
  git checkout main
  git merge --no-ff "lane/$lane"
  git push
done
```

---

## Out of scope (intentional gaps, no plans)

These are documented in ADR 0001 ("Scope — Known Gaps Accepted"):

- **HTTP-driven scale-to-zero** at the abstraction level of KEDA HTTP add-on
  (warm-replica workaround instead; Lane E plan covers wake-on-request).
- **Cloudflare Workers / R2 / D1 / KV / Queues** (capability #20) — not
  portable, integrated as application-layer feature only.
- **ArgoCD continuous reconciliation for IaC** (capability #16) — replaced
  by Atlantis (Lane D); revisit if Spacelift becomes affordable.

---

## Severity / theme view (filename tags)

The filename prefixes group by severity and domain (orthogonal to lanes):

- `_BACKLOG_HIGH_*` (4 plans) — audit HIGH severity gaps
- `_BACKLOG_ESTRATEGICOS_*` (5 plans) — strategic enablers from research
- `_BACKLOG_MEDIUM_*` (5 plans) — audit MEDIUM severity gaps
- `_BACKLOG_DATA_*` (6 plans) — storage and data plane
- `_BACKLOG_PLATFORM_*` (5 plans) — identity, tenancy, finops, providers

Use these tags when scanning by category. Use the lanes above when
planning execution.
