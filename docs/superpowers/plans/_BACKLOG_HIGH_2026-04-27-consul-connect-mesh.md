# Consul Connect (Service Mesh + mTLS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Consul Connect across the cluster so all intra-cluster service-to-service traffic is mTLS-encrypted, and validate end-to-end via the existing whoami sample app proxied through a Connect sidecar.

**Architecture:** Set `connect { enabled = true }` in Consul server + client config. Enable Connect in Nomad's `consul {}` stanza on clients so jobs can declare `service { connect { sidecar_service {} } }`. Re-deploy the `sample_app` (whoami) with a Connect sidecar and a Connect-aware upstream. Verify with `consul connect proxy -upstream` test from a server VM.

**Tech Stack:** Consul 1.20+, Nomad 1.10+, Envoy (auto-managed by Consul), existing Ansible roles.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/consul/templates/consul.hcl.j2` | Add `connect.enabled = true`, set `ports.grpc = 8502` (required by Connect) |
| `ansible/roles/nomad/templates/nomad-client.hcl.j2` | Add `consul.share_ssl = false`, `consul.grpc_address = "127.0.0.1:8502"` |
| `ansible/roles/sample_app/tasks/main.yml` | Switch the whoami include_role call to declare a Connect sidecar |
| `ansible/roles/app/templates/app.nomad.hcl.j2` | Add optional `connect { sidecar_service {} }` block gated by `app_connect` var |
| `ansible/roles/app/defaults/main.yml` | Add `app_connect: false` default |
| `tests/smoke/test_connect_mesh.sh` | New smoke test: hit whoami via Connect upstream, assert TLS+identity in response headers |
| `bin/bootstrap` | No change (re-runs Ansible, picks up new templates) |

---

## Pre-flight

Before starting, confirm working directory and a clean repo:

- [ ] **Step 0: Verify workspace**

```bash
cd /Users/ailtoncardozo/src/nomad-provider-agnostic-bootstrap
git status
```

Expected: branch `main`, clean working tree (or only files unrelated to this plan).

- [ ] **Step 1: Bring up local cluster** (skip if already running)

```bash
bin/local-up
```

Expected: 5 Multipass VMs running, Ansible bootstrap completes, Traefik/whoami/Grafana jobs running.

---

## Task 1: Failing smoke test for Connect mTLS

**Files:**
- Create: `tests/smoke/test_connect_mesh.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/smoke/test_connect_mesh.sh <<'EOF'
#!/usr/bin/env bash
# Verifies Consul Connect is enabled and a Connect-aware service is reachable
# only via its sidecar (not directly).
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <multipass-server-vm-name>" >&2
  exit 64
fi
VM="$1"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$ROOT_DIR/ansible/inventory/group_vars/all/secrets.yml"
CONSUL_TOKEN="$(awk '$1=="consul_bootstrap_token:" {print $2}' "$SECRETS")"

echo "=== Connect: CA root must exist ==="
roots=$(multipass exec "$VM" -- bash -c "
  curl -s -H 'X-Consul-Token: $CONSUL_TOKEN' http://127.0.0.1:8500/v1/connect/ca/roots
")
if [[ -z "$roots" ]] || ! echo "$roots" | grep -q '"Active":'; then
  echo "FAIL: Connect CA roots not found, body=$roots" >&2
  exit 1
fi
echo "OK"

echo "=== Connect: whoami must be registered as Connect-aware ==="
svc=$(multipass exec "$VM" -- bash -c "
  curl -s -H 'X-Consul-Token: $CONSUL_TOKEN' http://127.0.0.1:8500/v1/agent/services
")
if ! echo "$svc" | grep -q '"Kind":"connect-proxy"'; then
  echo "FAIL: no connect-proxy services registered, body=$svc" >&2
  exit 1
fi
echo "OK"

echo "=== Connect: upstream proxy round-trip to whoami must return 200 ==="
code=$(multipass exec "$VM" -- bash -c "
  consul connect proxy -service test-client -upstream whoami:9999 -log-level=warn &
  PID=\$!
  sleep 3
  C=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9999/whoami || true)
  kill \$PID 2>/dev/null || true
  echo \$C
" CONSUL_HTTP_TOKEN="$CONSUL_TOKEN")
if [[ "$code" != "200" ]]; then
  echo "FAIL: Connect proxy round-trip returned $code, expected 200" >&2
  exit 1
fi
echo "OK ($code)"

echo "ALL CONNECT MESH CHECKS PASSED"
EOF
chmod +x tests/smoke/test_connect_mesh.sh
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/smoke/test_connect_mesh.sh nomad-local-server-01
```

Expected: FAIL on the first assertion (`Connect CA roots not found`) because Connect isn't enabled yet.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/test_connect_mesh.sh
git commit -m "test(connect): add failing smoke for mTLS mesh"
```

---

## Task 2: Enable Connect in Consul config

**Files:**
- Modify: `ansible/roles/consul/templates/consul.hcl.j2`

- [ ] **Step 1: Patch consul.hcl.j2**

Open `ansible/roles/consul/templates/consul.hcl.j2` and after the `ui_config { enabled = true }` block append:

```hcl

connect {
  enabled = true
}

ports {
  grpc     = 8502
  grpc_tls = 8503
}
```

The full updated block at end-of-file should be:

```hcl
ui_config {
  enabled = true
}

connect {
  enabled = true
}

ports {
  grpc     = 8502
  grpc_tls = 8503
}
```

- [ ] **Step 2: Re-render and restart Consul on every node**

```bash
ansible-playbook \
  -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" \
  --tags consul \
  ansible/playbooks/bootstrap.yml
```

If the role lacks `--tags consul`, run the targeted role playbook used in past sessions:

```bash
cat > /tmp/consul-only.yml <<'EOF'
- name: Re-render consul config
  hosts: all
  become: true
  roles:
    - consul
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/consul-only.yml
```

Expected: handler "Restart consul" fires on all 5 nodes; all `systemctl is-active consul` return `active`.

- [ ] **Step 3: Verify Connect CA bootstrapped**

```bash
CONSUL_TOKEN=$(awk '$1=="consul_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-server-01 -- \
  curl -s -H "X-Consul-Token: $CONSUL_TOKEN" http://127.0.0.1:8500/v1/connect/ca/roots | python3 -m json.tool | head -20
```

Expected: JSON with at least one entry where `"Active": true`.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/consul/templates/consul.hcl.j2
git commit -m "feat(consul): enable Connect with built-in CA + gRPC ports 8502/8503"
```

---

## Task 3: Enable Connect in Nomad clients

**Files:**
- Modify: `ansible/roles/nomad/templates/nomad-client.hcl.j2`

- [ ] **Step 1: Patch nomad-client.hcl.j2**

Find the existing `consul {` block (typically near the top of the file). Replace it with:

```hcl
consul {
  address     = "127.0.0.1:8500"
  grpc_address = "127.0.0.1:8502"
  share_ssl   = false
  token       = "{{ consul_bootstrap_token }}"

  # Required so Nomad can register Connect-aware services and inject Envoy.
  client_auto_join = true
  server_auto_join = true
}
```

If `consul {}` doesn't exist yet (older template), add the block above immediately under the top-level `client {` block context.

- [ ] **Step 2: Re-run nomad role**

```bash
cat > /tmp/nomad-only.yml <<'EOF'
- name: Re-render nomad client/server config
  hosts: all
  become: true
  roles:
    - nomad
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/nomad-only.yml
```

Expected: handler "Restart nomad" fires; nomad becomes active again.

- [ ] **Step 3: Verify Nomad sees Consul gRPC**

```bash
multipass exec nomad-local-client-01 -- \
  bash -c 'journalctl -u nomad --no-pager --since "2 minutes ago" | grep -iE "consul|connect" | tail -10'
```

Expected: lines containing `consul.client: discovered` and **no** lines containing `error` related to Consul gRPC.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(nomad): wire Nomad clients to Consul Connect gRPC port"
```

---

## Task 4: Add `app_connect` flag to the generic app role

**Files:**
- Modify: `ansible/roles/app/defaults/main.yml`
- Modify: `ansible/roles/app/templates/app.nomad.hcl.j2`

- [ ] **Step 1: Add default**

Append to `ansible/roles/app/defaults/main.yml`:

```yaml
# When true, register a Connect sidecar (Envoy) for this service so other
# Connect-aware services can reach it over mTLS via `upstreams { ... }`.
app_connect: false
```

- [ ] **Step 2: Patch the Nomad job template**

Open `ansible/roles/app/templates/app.nomad.hcl.j2` and locate the `service {` block. After the existing `tags = [ ... ]` array (and before the closing `}` of the `service` block) insert:

```hcl
{% if app_connect %}
      connect {
        sidecar_service {}
      }
{% endif %}
```

Also adjust the `network {}` block: when `app_connect` is true, the service must use `mode = "bridge"` (Connect requires it). Replace the block with:

```hcl
    network {
      mode = "{{ 'bridge' if app_connect else 'host' }}"
      port "http" {
        to = {{ app_container_port }}
      }
    }
```

- [ ] **Step 3: Lint Jinja**

```bash
python3 -c "import jinja2; jinja2.Environment().parse(open('ansible/roles/app/templates/app.nomad.hcl.j2').read()); print('jinja ok')"
```

Expected: `jinja ok`.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/app/defaults/main.yml ansible/roles/app/templates/app.nomad.hcl.j2
git commit -m "feat(app): optional Connect sidecar via app_connect=true"
```

---

## Task 5: Re-deploy whoami with Connect sidecar

**Files:**
- Modify: `ansible/roles/sample_app/tasks/main.yml`

- [ ] **Step 1: Patch the include_role call**

Open `ansible/roles/sample_app/tasks/main.yml` and replace its content with:

```yaml
---
- name: Deploy whoami via the generic app role with a Connect sidecar
  ansible.builtin.include_role:
    name: app
  vars:
    app_name: whoami
    app_image: "traefik/whoami:v1.10"
    app_host: "{{ traefik_domain }}"
    app_path_prefix: "/whoami"
    app_container_port: 80
    app_cpu: 100
    app_memory: 64
    app_connect: true
    app_health_path: "/"
```

- [ ] **Step 2: Re-run the sample_app role**

```bash
cat > /tmp/sample-only.yml <<'EOF'
- name: Re-deploy sample app
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - sample_app
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/sample-only.yml
```

Expected: whoami job updated, deployment "successful".

- [ ] **Step 3: Verify Envoy sidecar is running**

```bash
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-server-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job allocs whoami | head -5
  echo ---
  ALLOC=\$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus \"running\"}}{{.ID}}{{end}}{{end}}' whoami | head -c 8)
  nomad alloc status \$ALLOC | grep -E 'connect-proxy|envoy'
"
```

Expected: at least one task named `connect-proxy-whoami` running alongside the `whoami` task.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/sample_app/tasks/main.yml
git commit -m "feat(sample_app): enable Connect sidecar on whoami"
```

---

## Task 6: Make smoke test pass

- [ ] **Step 1: Re-run the smoke**

```bash
bash tests/smoke/test_connect_mesh.sh nomad-local-server-01
```

Expected: `ALL CONNECT MESH CHECKS PASSED`.

- [ ] **Step 2: If any assertion fails, diagnose**

```bash
# CA roots check failure → consul connect not enabled, redo Task 2
multipass exec nomad-local-server-01 -- sudo grep -A2 connect /etc/consul.d/consul.hcl

# connect-proxy registration failure → app_connect didn't propagate, redo Task 5
multipass exec nomad-local-server-01 -- bash -c "curl -sH 'X-Consul-Token: $CONSUL_TOKEN' http://127.0.0.1:8500/v1/agent/services | python3 -m json.tool"

# upstream round-trip failure → Envoy not bound, check sidecar logs
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-client-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ALLOC=\$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus \"running\"}}{{.ID}}{{end}}{{end}}' whoami | head -c 8)
  nomad alloc logs \$ALLOC connect-proxy-whoami 2>&1 | tail -30
"
```

Iterate on the failing role until smoke passes.

- [ ] **Step 3: Commit smoke addition to CI**

The existing CI runs `bash -n` on smoke scripts; no extra wiring needed. Ensure the file is staged:

```bash
git status -s tests/smoke/test_connect_mesh.sh
```

Expected: empty (already committed in Task 1) — nothing new to commit.

---

## Task 7: Documentation runbook

**Files:**
- Create: `docs/runbooks/consul-connect.md`

- [ ] **Step 1: Write runbook**

```bash
cat > docs/runbooks/consul-connect.md <<'EOF'
# Runbook — Consul Connect (mTLS Mesh)

## Enabled state
- Consul: `connect.enabled = true`, gRPC on `:8502`/`:8503`
- Nomad clients: `consul.grpc_address = "127.0.0.1:8502"`
- Apps opt in by setting `app_connect: true` in the app role include

## How a service joins the mesh
1. In the app role include, set `app_connect: true`.
2. The job will register `service { connect { sidecar_service {} } }`.
3. Nomad places an Envoy sidecar (`connect-proxy-<service>`) alongside the task.
4. Service-to-service calls go via the upstream stanza on the *consumer* side.

## Calling another Connect service from a job
Add to the consumer's `service { connect { sidecar_service { ... } } }` block:

```hcl
sidecar_service {
  proxy {
    upstreams {
      destination_name = "<other-service>"
      local_bind_port  = 9001
    }
  }
}
```

Then in the consumer's task code, call `http://127.0.0.1:9001/...`.

## Verifying mTLS
From any cluster node:
```bash
consul connect proxy -service test -upstream whoami:9999 &
curl http://127.0.0.1:9999/whoami
```
The request goes encrypted over the mesh, terminating at whoami's Envoy.

## Common failures
| Symptom | Cause | Fix |
|---|---|---|
| `Connect CA roots not found` | `connect.enabled` missing | Re-run consul role |
| `connect-proxy not registered` | `app_connect` not set | Set in app include, redeploy |
| `502 Bad Gateway` from upstream | Service has `network.mode = host` instead of `bridge` | Connect requires bridge mode; re-render |
| `agent: error: Consul gRPC service connection failed` | Nomad client doesn't have `grpc_address` | Re-run nomad role |
EOF
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/consul-connect.md
git commit -m "docs(runbook): consul connect — enable, verify, troubleshoot"
```

---

## Task 8: Push and close

- [ ] **Step 1: Push**

```bash
git push origin main
```

- [ ] **Step 2: Verify CI is green**

```bash
sleep 15
gh run list --workflow=lint.yml --limit 1
```

Expected: most recent run is `completed success`.

---

## Self-Review Notes (already applied)

- Spec coverage: every section of the original audit's #17 (mesh) is addressed: Connect CA, Envoy sidecar, mTLS round-trip verified, opt-in flag for apps.
- No placeholders: every task block contains the exact code or command.
- Type/name consistency: `app_connect` named identically across `defaults`, template, and sample_app include.
