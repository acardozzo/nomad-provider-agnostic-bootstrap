# Automation Checklist

This checklist tracks what is already automated in the bootstrap and what still needs work before it becomes a more hands-off platform.

## Fully Automated

- [x] Provider-selected infrastructure provisioning with Terraform
- [x] `3` Nomad servers and `2` clients
- [x] SSH key wiring
- [x] Vultr VPC + firewall + instances
- [x] Linode VPC + subnet + firewall + private VPC interface + instances
- [x] Inventory generation from Terraform outputs
- [x] Docker installation via Ansible
- [x] Consul installation, gossip encryption, ACL bootstrap
- [x] Nomad installation, gossip encryption, ACL bootstrap
- [x] Traefik with Let's Encrypt ACME, HTTP→HTTPS redirect, TLS dashboard with basic-auth
- [x] Generic `app` role for any Docker app behind Traefik (hostname rule, TLS, healthchecks, canary updates)
- [x] Sample app deployment (`whoami`) via the generic app role
- [x] Canary-based rolling updates with health checks (Traefik + every app)
- [x] Periodic Consul snapshots via Nomad batch job (6h, 14-snapshot retention)
- [x] Monitoring: node_exporter (system job), Prometheus with Consul SD + Nomad telemetry, Grafana behind TLS
- [x] Horizontal app autoscaling (nomad-autoscaler + Prometheus APM, opt-in per app)
- [x] System hardening: fail2ban, unattended-upgrades, sshd hardening, UFW with private-net allowlist
- [x] Encrypted operator secrets via sops + age (`secrets/cluster.yaml` → VULTR_API_KEY/LINODE_TOKEN/SSH key)
- [x] CI: lint workflow on every PR (ansible-lint, yamllint, terraform fmt/validate, jinja parse, bash -n)
- [x] CI: terraform plan-on-PR with S3-compatible remote state
- [x] CI: terraform apply-on-merge gated by GitHub Environments approval
- [x] Local validation via `Makefile` (`make lint`, `make syntax-check` — containerized ansible)
- [x] One-command flow with `bin/apply`, `bin/bootstrap`, `bin/destroy`
- [x] DNS records (operator-managed prerequisite, automation-checked at smoke)
- [x] Let's Encrypt / ACME certificates
- [x] Sample app domain routing by hostname
- [x] Post-deploy smoke tests against live endpoints (ingress, ACL, TLS)
- [x] Service discovery convention demonstrated and documented (Consul Catalog + Traefik tags)

## Partially Automated

- [-] **Cluster (node-level) autoscaling** — `nomad-autoscaler` is deployed and runs horizontal app scaling. There is no upstream target plugin for Vultr or Linode, so node count is still set in `terraform.tfvars`. App-level scaling works today; provider-specific node-target plugin is required for full hands-off node scaling.
- [-] **Backups offsite** — Consul snapshots are taken on schedule and pruned, but they live on a client host volume. Pushing them to provider object storage requires an S3-compat creds drop into the snapshot job (the job already runs in Nomad, just needs `aws s3 cp` after the snapshot).
- [-] **Provider failover / multi-provider cluster** — explicitly out of scope (see "Not required" notes below).

## Not Automated (intentionally deferred)

- [ ] **Vault integration** — sops + age covers operator-supplied secrets at rest; runtime cluster secrets (gossip, ACL tokens) are 0600 on the operator workstation. Vault becomes worthwhile when there are multiple consumers or rotation policy.
- [ ] **Artifact / image build pipeline** — out of scope; belongs in each app's repo.
- [ ] **Provider failover / multi-provider single-cluster** — out of scope; the recommended pattern is two independent clusters fronted by DNS, which this repo can already produce.

## How to verify locally

```bash
make lint           # ansible-lint, yamllint, terraform fmt, jinja parse, bash -n
make syntax-check   # ansible-playbook --syntax-check via container
```

## How to verify post-deploy

`bin/bootstrap` runs these automatically:

- `tests/smoke/test_ingress_assets.sh`
- `tests/smoke/test_acl.sh <server_public_ip>` (manual; needs IP arg)
- `tests/smoke/test_tls_ingress.sh` (when `traefik_domain` is set)
