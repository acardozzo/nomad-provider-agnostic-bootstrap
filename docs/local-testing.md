# Local Testing

Three layers of local validation, from fastest to most realistic.

## Layer 1 — Static checks (no runtime)

```bash
make lint          # ansible-lint (containerized), yamllint, jinja parse,
                   # bash -n, terraform fmt + validate
make syntax-check  # ansible-playbook --syntax-check via container
```

Catches: YAML errors, Jinja errors, terraform syntax/refs, undeclared playbook
references, bash syntax. ~10 seconds.

Does NOT catch: runtime behavior.

## Layer 2 — Traefik routing smoke (Docker compose)

Single-host stack with Traefik + whoami (no Consul, no Nomad). Validates that
the Traefik flags we render in production are accepted, that hostname routing
works, and that the HTTP→HTTPS redirect fires.

```bash
make local-traefik-up      # docker compose up
make local-traefik-smoke   # asserts redirect, 200 over HTTPS, dashboard route
make local-traefik-down
```

URLs (the smoke test uses Host header so /etc/hosts is optional):

- `https://localhost:8443/whoami`        (with `Host: cluster.local`)
- `https://localhost:8443/api/overview`  (with `Host: traefik.cluster.local`)

Self-signed cert; pass `-k` to curl.

Catches: Traefik flag/argument errors, label/tag rule errors, port conflicts.

Does NOT catch: Consul Catalog provider behavior (uses Docker provider here),
Nomad scheduling, ACL gates, multi-node gossip, hardening, ACME issuance.

## Layer 3 — Full cluster replica (Multipass, 5 VMs)

Brings up 3 server + 2 client Ubuntu 24.04 VMs locally and runs the **same**
Ansible bootstrap that targets cloud nodes. Real systemd, real Consul/Nomad
agents, real UFW, real fail2ban, real rolling updates, real periodic backup
jobs, real Prometheus + Grafana.

### Prerequisites

```bash
brew install --cask multipass    # macOS
sudo snap install multipass      # Linux

brew install ansible             # macOS
pipx install ansible             # Linux
```

### Run

```bash
make local-cluster-up
```

This script:

1. Generates `~/.ssh/id_ed25519_nomad_local` if missing.
2. Launches 5 VMs (`nomad-local-server-{01..03}`, `nomad-local-client-{01..02}`)
   with cloud-init wiring the SSH key into root and ubuntu users.
3. Renders `ansible/inventory/hosts.ini` from `multipass list`.
4. Writes `ansible/inventory/group_vars/all_local.yml` with `acme_enabled: false`
   so Traefik uses its self-signed cert (Let's Encrypt cannot reach a VM behind
   your laptop).
5. Runs `secrets.yml` then `bootstrap.yml`.

### Verify

```bash
# Add to /etc/hosts (the script prints the right line):
sudo sh -c 'echo "<client_ip> cluster.local traefik.cluster.local grafana.cluster.local" >> /etc/hosts'

curl -k https://cluster.local/whoami           # 200 from whoami
curl -k -u admin:<pw> https://traefik.cluster.local/api/overview
curl -k https://grafana.cluster.local/         # Grafana login
```

Dashboard password: `awk -F'"' '/^dashboard_basic_auth_password:/ {print $2}' ansible/inventory/group_vars/secrets.yml`

### Teardown

```bash
make local-cluster-down
```

### Resource budget

Default: 5 × 1 CPU / 1 GB RAM / 5 GB disk = 5 vCPU and 5 GB RAM total.
Override with env vars:

```bash
LOCAL_CPUS=2 LOCAL_MEM=2G make local-cluster-up
```

### What this DOES exercise

- Multi-node Raft + gossip (Consul + Nomad)
- ACL bootstrap and token persistence
- Gossip encryption end-to-end
- Hardening role (UFW rules, fail2ban, sshd config)
- Traefik with Consul Catalog provider
- Canary rolling updates (deploy whoami v1, then submit a change, watch the canary)
- Periodic Consul snapshots (the job runs every 6h, you can `nomad job dispatch consul-snapshot/periodic-...` to trigger)
- Prometheus scraping Consul-discovered targets + Nomad telemetry
- Grafana login

### What this does NOT exercise

- Real ACME issuance (no public IP, no public DNS — `acme_enabled` is forced false).
  To test the ACME path itself, set `acme_caserver` to Pebble
  (https://github.com/letsencrypt/pebble) or Let's Encrypt staging and run on a
  VM that has a public IP.
- Provider-side Terraform (no Vultr/Linode resources are touched).
- True production firewalling (UFW inside the VM is real, but the host's macOS
  firewall isn't).

## Choosing a layer

| Need | Layer |
|---|---|
| Iterating on a Traefik label or rule | 2 (Docker) |
| Iterating on an Ansible role | 3 (Multipass) |
| Iterating on a Terraform resource | `make lint` + cloud staging |
| Validating end-to-end before a real `bin/apply` | 3 (Multipass) |
| Pre-commit / CI gate | 1 (`make lint`) |

`make lint` runs in CI on every PR. Layer 3 is slow enough that it stays manual.
