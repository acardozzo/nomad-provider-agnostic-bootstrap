# Workload Identity (Nomad WI + Vault Auth) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace shared bootstrap tokens (Nomad/Consul) for workload-to-Vault auth with **Nomad Workload Identity (JWT)** and a dedicated Vault JWT auth method. Each task gets a short-lived signed JWT injected by Nomad; Vault verifies the signature and issues a scoped token. Closes audit #12.

**Architecture:** Nomad servers issue JWTs signed by their built-in JWKS endpoint. Vault is configured with a `jwt` auth method pointing at Nomad's JWKS URL. A Vault role maps `nomad/job/<job-id>` claims to specific policies. Apps declare `identity { aud = ["vault.io"] }` in their tasks; Nomad mints the JWT, the consul-template stanza in the task exchanges it via `auth/jwt/login` for a Vault token.

**Tech Stack:** Nomad 1.7+ Workload Identity (built-in), Vault 1.18 JWT auth method, existing Vault role from prior plan.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/nomad/templates/nomad-server.hcl.j2` | Configure JWT issuer, JWKS endpoint |
| `ansible/roles/vault/tasks/main.yml` | Configure jwt auth method + policies + roles |
| `ansible/roles/app/templates/app.nomad.hcl.j2` | Add `identity {}` block + Vault template auth-via-jwt |
| `ansible/inventory/group_vars/all/defaults.yml` | wi_audience, vault_jwt_role |
| `tests/smoke/test_workload_identity.sh` | A task with WI fetches a Vault secret without any static token |

---

## Task 1: Defaults + smoke

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Workload Identity
wi_audience: "vault.io"
vault_jwt_role: "nomad-workloads"
EOF

cat > tests/smoke/test_workload_identity.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")

echo "=== Submit a wi-test job that reads a vault secret via WI ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  cat > /tmp/wi.hcl <<HCL
job \"wi-test\" {
  datacenters = [\"dc1\"]
  type = \"batch\"
  group \"x\" {
    task \"x\" {
      driver = \"docker\"
      identity { name = \"vault\" aud = [\"vault.io\"] }
      template {
        data = <<EOT
{{ '{{' }} with secret \"secret/data/wi-smoke\" {{ '}}' }}{{ '{{' }} .Data.data.value {{ '}}' }}{{ '{{' }} end {{ '}}' }}
EOT
        destination = \"local/out\"
      }
      config { image = \"alpine\" command = \"sh\" args = [\"-c\", \"cat /local/out\"] }
    }
  }
}
HCL
  nomad job run /tmp/wi.hcl
"
sleep 10
out=$(multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ALLOC=\$(nomad job allocs -t '{{range .}}{{.ID}}{{end}}' wi-test | head -c 8)
  nomad alloc logs \$ALLOC
")
echo "$out" | grep -q wi-secret-value || { echo "FAIL: $out"; exit 1; }
echo "OK"
echo "ALL WORKLOAD IDENTITY CHECKS PASSED"
EOF
chmod +x tests/smoke/test_workload_identity.sh

git add ansible/inventory/group_vars/all/defaults.yml tests/smoke/test_workload_identity.sh
git commit -m "test(workload-identity): defaults + failing smoke"
```

---

## Task 2: Configure Nomad as JWT issuer

In `nomad-server.hcl.j2` add:

```hcl
server {
  ...
  default_scheduler_config {
    pause_eval_broker = false
  }
}

# Issue JWTs signed with the Nomad keyring
keyring {
  active_key_id = "default"
  default_action {
    encryption_capability = "active"
  }
}
```

Note: Nomad 1.7+ enables WI by default. Verify with:

```bash
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-server-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  curl -sH \"X-Nomad-Token: \$NOMAD_TOKEN\" http://127.0.0.1:4646/.well-known/jwks.json
"
```

Expected: JSON with `keys` array.

```bash
git add ansible/roles/nomad/templates/nomad-server.hcl.j2
git commit -m "feat(nomad): explicit keyring for workload identity"
```

---

## Task 3: Vault JWT auth method

Append to `ansible/roles/vault/tasks/main.yml`:

```yaml
- name: Enable JWT auth method (idempotent)
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8200/v1/sys/auth/jwt"
    method: POST
    headers: { X-Vault-Token: "{{ vault_root_token }}" }
    body: '{"type":"jwt"}'
    body_format: json
    status_code: [204, 400]
  delegate_to: localhost
  become: false
  run_once: true

- name: Configure JWT auth method
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8200/v1/auth/jwt/config"
    method: POST
    headers: { X-Vault-Token: "{{ vault_root_token }}" }
    body: '{"jwks_url":"http://{{ hostvars[groups[''servers''][0]].ansible_host }}:4646/.well-known/jwks.json","default_role":"{{ vault_jwt_role }}"}'
    body_format: json
    status_code: 204
  delegate_to: localhost
  become: false
  run_once: true

- name: Create Vault role for Nomad workloads
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8200/v1/auth/jwt/role/{{ vault_jwt_role }}"
    method: POST
    headers: { X-Vault-Token: "{{ vault_root_token }}" }
    body: |
      {
        "role_type": "jwt",
        "user_claim": "nomad_job_id",
        "bound_audiences": ["{{ wi_audience }}"],
        "token_policies": ["app-default"],
        "token_ttl": "1h",
        "token_max_ttl": "24h",
        "claim_mappings": {
          "nomad_namespace": "namespace",
          "nomad_job_id": "job_id"
        }
      }
    body_format: json
    status_code: [200, 204]
  delegate_to: localhost
  become: false
  run_once: true

- name: Seed wi-smoke secret for the smoke test
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8200/v1/secret/data/wi-smoke"
    method: POST
    headers: { X-Vault-Token: "{{ vault_root_token }}" }
    body: '{"data":{"value":"wi-secret-value"}}'
    body_format: json
    status_code: [200, 204]
  delegate_to: localhost
  become: false
  run_once: true
```

```bash
git add ansible/roles/vault/tasks/main.yml
git commit -m "feat(vault): jwt auth method + nomad-workloads role"
```

---

## Task 4: Wire identity into the app role

In `ansible/roles/app/templates/app.nomad.hcl.j2` add to each task:

```hcl
{% if app_use_vault %}
      identity {
        name = "vault"
        aud  = ["{{ wi_audience }}"]
        env  = false
        file = false
      }

      vault {
        role            = "{{ vault_jwt_role }}"
        change_mode     = "noop"
      }
{% endif %}
```

Add `app_use_vault: false` to `ansible/roles/app/defaults/main.yml`.

```bash
git add ansible/roles/app/
git commit -m "feat(app): optional workload-identity Vault auth"
```

---

## Task 5: Run + smoke + runbook + push

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags vault,nomad
bash tests/smoke/test_workload_identity.sh nomad-local-server-01
```

```bash
cat > docs/runbooks/workload-identity.md <<'EOF'
# Runbook — Workload Identity (Nomad → Vault)

## How it works
1. Nomad server signs a short-lived JWT for each task (`identity {}` block).
2. Task exchanges JWT for a Vault token at `auth/jwt/login` (Nomad's
   `vault {}` block does this transparently when WI is enabled).
3. Vault token grants policies based on the JWT's `nomad_job_id` claim.

## Enabling on a job
```hcl
task "x" {
  identity {
    name = "vault"
    aud  = ["vault.io"]
  }
  vault {
    role = "nomad-workloads"
  }
  template {
    data        = <<EOT
{{ with secret "secret/data/myapp" }}{{ .Data.data.password }}{{ end }}
EOT
    destination = "secrets/env"
    env         = true
  }
}
```

## Why this beats shared bootstrap tokens
- No token in `secrets.yml` to leak.
- Each task gets a distinct identity, scoped to a single policy.
- Tokens are 1h TTL with auto-renewal; revoked when the alloc stops.

## Migration plan
1. Add `app_use_vault: true` to apps that need secrets.
2. Define a per-app policy: `vault policy write <app> - <<POL ... POL`.
3. Update `nomad-workloads` role to map specific job_ids → specific policies via `bound_claims`.
4. Drop the static `vault {} { token = ... }` from job templates once verified.
EOF
git add docs/runbooks/workload-identity.md
git commit -m "docs(runbook): workload identity"
git push origin main
```

---

## Self-Review

- Audit #12 covered: WI replaces static token in app→Vault path.
- No placeholders.
- Type/name consistency: `wi_audience`, `vault_jwt_role` aligned.
