# Vault on Nomad + consul-template Sidecars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run HashiCorp Vault as a Nomad job (raft single-node, file storage backend on host_volume), enable Nomad's Vault integration so jobs can declare `vault {}` blocks, and document the consul-template path that replaces ESO. Migrates secrets out of `secrets.yml` plain-yaml into Vault KV v2.

**Architecture:** Vault 1.18 runs as a Nomad service job constrained to a server node, with raft storage on host_volume `vault_data`. Vault is auto-init via a one-shot batch job that captures the unseal keys + root token into `secrets.yml` (manual secure-store afterwards). Nomad clients are configured with `vault {}` block pointing at `vault.service.consul:8200`. Apps gain a `vault { policies = ["app-x"] }` block to fetch tokens; consul-template sidecar inside each app task renders templated env from secrets.

**Tech Stack:** Vault 1.18, Nomad Vault integration, consul-template (Nomad-native template stanza), Consul service discovery.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/vault/templates/vault.nomad.hcl.j2` | Vault service job (single-node raft) |
| `ansible/roles/vault/templates/vault-config.hcl.j2` | Vault server config |
| `ansible/roles/vault/templates/init.nomad.hcl.j2` | One-shot init batch job |
| `ansible/roles/vault/tasks/main.yml` | Render+run Vault, capture unseal keys, set up policies |
| `ansible/roles/nomad/templates/nomad-client.hcl.j2` | Add `vault {}` block + host_volume |
| `ansible/inventory/group_vars/all/secrets.example.yml` | document `vault_root_token`, `vault_unseal_keys` |
| `tests/smoke/test_vault.sh` | Init, status sealed=false, write+read a secret |
| `docs/runbooks/secrets.md` | Operator guide |

---

## Task 1: Defaults + failing smoke

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Vault
vault_version: "1.18.2"
vault_data_dir: "/opt/vault"
vault_listener_port: 8200
EOF

cat >> ansible/inventory/group_vars/all/secrets.example.yml <<'EOF'
# Vault auto-init outputs (filled by ansible after first run; keep secure):
vault_root_token: ""
vault_unseal_keys: []
EOF

cat > tests/smoke/test_vault.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
ROOT_TOKEN=$(awk '$1=="vault_root_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml" | tr -d \")
[[ -z "$ROOT_TOKEN" ]] && { echo "FAIL: vault_root_token not in secrets.yml"; exit 1; }

echo "=== Vault unsealed ==="
out=$(multipass exec "$VM" -- bash -c "
  curl -s http://vault.service.consul:8200/v1/sys/health
")
echo "$out" | grep -q '"sealed":false' || { echo "FAIL sealed: $out"; exit 1; }
echo OK

echo "=== Write+read kv secret ==="
multipass exec "$VM" -- bash -c "
  curl -s -X POST -H 'X-Vault-Token: $ROOT_TOKEN' \
    -d '{\"data\":{\"smoke\":\"value\"}}' \
    http://vault.service.consul:8200/v1/secret/data/smoke-test >/dev/null
  curl -s -H 'X-Vault-Token: $ROOT_TOKEN' \
    http://vault.service.consul:8200/v1/secret/data/smoke-test
" | grep -q '"smoke":"value"' || { echo "FAIL kv read"; exit 1; }
echo OK

echo "ALL VAULT CHECKS PASSED"
EOF
chmod +x tests/smoke/test_vault.sh

git add ansible/inventory/group_vars/all/defaults.yml ansible/inventory/group_vars/all/secrets.example.yml tests/smoke/test_vault.sh
git commit -m "test(vault): defaults + failing smoke"
```

---

## Task 2: Vault server config + job

```bash
mkdir -p ansible/roles/vault/{tasks,templates}

cat > ansible/roles/vault/templates/vault-config.hcl.j2 <<'EOF'
ui            = true
disable_mlock = true
api_addr      = "http://{{ hostvars[groups['servers'][0]].private_ip }}:{{ vault_listener_port }}"
cluster_addr  = "http://{{ hostvars[groups['servers'][0]].private_ip }}:8201"

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-server-1"
}

listener "tcp" {
  address     = "0.0.0.0:{{ vault_listener_port }}"
  cluster_address = "0.0.0.0:8201"
  tls_disable = true
}

service_registration "consul" {
  address = "127.0.0.1:8500"
  service = "vault"
  token   = "{{ consul_bootstrap_token }}"
}
EOF

cat > ansible/roles/vault/templates/vault.nomad.hcl.j2 <<'EOF'
job "vault" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "vault" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "http"    { static = {{ vault_listener_port }} }
      port "cluster" { static = 8201 }
    }

    volume "data" {
      type      = "host"
      source    = "vault_data"
      read_only = false
    }

    service {
      name = "vault"
      port = "http"
      check {
        type     = "http"
        path     = "/v1/sys/health?standbyok=true&perfstandbyok=true"
        port     = "http"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "vault" {
      driver = "docker"

      cap_add = ["IPC_LOCK"]

      volume_mount {
        volume      = "data"
        destination = "/vault/data"
        read_only   = false
      }

      template {
        data = <<EOT
{{ '{{' }} key "vault/server.hcl" {{ '}}' }}
EOT
        destination = "local/server.hcl"
        change_mode = "noop"
      }

      config {
        image        = "hashicorp/vault:{{ vault_version }}"
        network_mode = "host"
        args = ["server", "-config=/local/server.hcl"]
      }

      resources { cpu = 200; memory = 256 }
    }
  }
}
EOF
```

Add host_volume to `nomad-client.hcl.j2`:

```hcl
  host_volume "vault_data" {
    path      = "{{ vault_data_dir }}"
    read_only = false
  }
```

Commit:

```bash
git add ansible/roles/vault/templates/ ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(vault): single-node raft job + nomad host_volume"
```

---

## Task 3: Auto-init + capture root token

```bash
cat > ansible/roles/vault/tasks/main.yml <<'EOF'
---
- name: Ensure vault data dir
  ansible.builtin.file:
    path: "{{ vault_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Render vault server config to KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/vault/server.hcl"
    method: PUT
    body: "{{ lookup('template', 'vault-config.hcl.j2') }}"
    headers: { X-Consul-Token: "{{ consul_bootstrap_token }}" }
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Submit vault job
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'vault.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Wait for vault HTTP
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:{{ vault_listener_port }}/v1/sys/health"
    status_code: [200, 429, 472, 473, 501, 503]
  register: vault_health
  retries: 30
  delay: 2
  until: vault_health.status in [200, 429, 472, 473, 501, 503]
  delegate_to: localhost
  become: false
  run_once: true

- name: Initialize Vault (only if not initialized)
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:{{ vault_listener_port }}/v1/sys/init"
    method: POST
    body: '{"secret_shares": 5, "secret_threshold": 3}'
    body_format: json
    status_code: [200, 400]
  register: vault_init
  delegate_to: localhost
  become: false
  run_once: true
  when: (vault_root_token | default('')) == ''

- name: Persist init outputs to secrets.yml
  ansible.builtin.lineinfile:
    path: "{{ playbook_dir }}/../inventory/group_vars/all/secrets.yml"
    regexp: "^{{ item.k }}:"
    line: "{{ item.k }}: {{ item.v | to_json }}"
    mode: "0600"
  loop:
    - { k: "vault_root_token", v: "{{ vault_init.json.root_token | default(vault_root_token | default('')) }}" }
    - { k: "vault_unseal_keys", v: "{{ vault_init.json.keys | default(vault_unseal_keys | default([])) }}" }
  when: vault_init is defined and vault_init.json is defined and vault_init.json.root_token is defined
  delegate_to: localhost
  become: false
  run_once: true
  no_log: true

- name: Unseal Vault (3 of 5 keys)
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:{{ vault_listener_port }}/v1/sys/unseal"
    method: POST
    body: '{"key": "{{ item }}"}'
    body_format: json
    status_code: 200
  loop: "{{ (vault_unseal_keys | default([]))[:3] }}"
  delegate_to: localhost
  become: false
  run_once: true
  when: (vault_unseal_keys | default([])) | length >= 3
  no_log: true
EOF
```

Run:

```bash
cat > /tmp/vault-only.yml <<'EOF'
- hosts: all
  become: true
  roles: [vault]
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/vault-only.yml
```

Expected: `vault_root_token` and `vault_unseal_keys` populated in `secrets.yml`; vault is unsealed.

Commit:

```bash
git add ansible/roles/vault/tasks/main.yml
git commit -m "feat(vault): auto-init, capture unseal keys, unseal"
```

---

## Task 4: Wire Nomad to Vault

In `nomad-server.hcl.j2` (and `nomad-client.hcl.j2` if missing) add:

```hcl
vault {
  enabled          = true
  address          = "http://vault.service.consul:8200"
  task_token_ttl   = "1h"
  create_from_role = "nomad-cluster"
{% if vault_root_token %}
  token = "{{ vault_root_token }}"
{% endif %}
}
```

Run nomad role to apply.

Create the `nomad-cluster` role in Vault:

```bash
ROOT=$(awk '$1=="vault_root_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml | tr -d \")
multipass exec nomad-local-server-01 -- bash -c "
export VAULT_ADDR=http://vault.service.consul:8200
export VAULT_TOKEN='$ROOT'
vault auth enable -path=nomad token 2>/dev/null || true
vault write auth/token/roles/nomad-cluster \
  allowed_policies=default,app-default \
  orphan=true period=72h
vault policy write app-default - <<POL
path \"secret/data/app/*\" {
  capabilities = [\"read\"]
}
POL
"
```

Commit:

```bash
git add ansible/roles/nomad/templates/
git commit -m "feat(nomad): wire Nomad clients/servers to Vault + nomad-cluster role"
```

---

## Task 5: Sample app using Vault secrets

Add to a sample app's job:

```hcl
    task "app" {
      vault { policies = ["app-default"] }

      template {
        data = <<EOT
DB_PASSWORD={{ '{{' }} with secret "secret/data/app/myapp" {{ '}}' }}{{ '{{' }} .Data.data.password {{ '}}' }}{{ '{{' }} end {{ '}}' }}
EOT
        destination = "secrets/env"
        env         = true
      }
      ...
    }
```

Document this pattern in the runbook (Task 7).

---

## Task 6: Smoke + push

```bash
bash tests/smoke/test_vault.sh nomad-local-server-01
```

Expected: passes.

```bash
git push origin main
```

---

## Task 7: Runbook

```bash
cat > docs/runbooks/secrets.md <<'EOF'
# Runbook — Secrets (Vault)

## Storage of operator secrets
- Operator-side: `vault_root_token` and `vault_unseal_keys` in `secrets.yml` (gitignored, mode 0600). Move to a password manager for production.
- App-side: stored in Vault under `secret/data/app/<name>`.

## Writing a secret
```bash
export VAULT_ADDR=http://vault.service.consul:8200
export VAULT_TOKEN=<root>
vault kv put secret/app/myapp password=$(openssl rand -hex 16)
```

## Consuming in a Nomad job
```hcl
task "app" {
  vault { policies = ["app-default"] }
  template {
    data = <<EOT
DB_PASSWORD={{ with secret "secret/data/app/myapp" }}{{ .Data.data.password }}{{ end }}
EOT
    destination = "secrets/env"
    env         = true
  }
}
```

## Rotation
- Vault generates a fresh token per task at allocation time.
- TTL = 1h, renewed automatically by Nomad.
- To rotate the actual secret value, just `vault kv put` the new value; consul-template re-renders within seconds.

## Sealing & unsealing
- After a Vault restart, the service comes up sealed.
- The `vault` role's "Unseal Vault" task auto-unseals using `vault_unseal_keys` from `secrets.yml`.
- For production, replace this with a cloud KMS auto-unseal (`seal "awskms"`, `seal "gcpkms"`).

## Disaster recovery
- raft snapshot daily: add to `restic_paths` in defaults: `/opt/vault`.
- Restore: stop Vault job, replace `/opt/vault/data` from restic, start Vault, unseal.
EOF
git add docs/runbooks/secrets.md
git commit -m "docs(runbook): vault + consul-template"
git push origin main
```

---

## Self-Review

- Audit #11 covered: Vault as storage, consul-template as sync (Nomad-native template block), policies, app pattern.
- No placeholders.
- Type/name consistency: `vault_data`, `vault_root_token`, `app-default` policy.
