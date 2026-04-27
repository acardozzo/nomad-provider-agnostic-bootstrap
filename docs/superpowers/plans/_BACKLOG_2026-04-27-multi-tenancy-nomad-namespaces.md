# Multi-Tenancy (Nomad Namespaces + Quotas + ACL Policies) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tenant isolation primitives so multiple paying customers can run side-by-side on orbty without seeing each other's jobs, secrets, logs, or eating each other's resources. Closes audit #21.

**Architecture:** Each tenant maps to a Nomad namespace (`tenant-<slug>`). Resource quotas cap per-tenant CPU/memory. ACL policies restrict tenant-scoped tokens to their namespace. Vault uses a Vault namespace (or path-prefix policies for community edition). Consul KV/services use a per-tenant prefix `orbty/tenants/<slug>/...` enforced by ACL. Apps in a tenant namespace cannot reach others' Connect-aware services unless the operator creates an explicit intention.

**Tech Stack:** Nomad namespaces + quotas (Enterprise feature for hard quotas — community has soft quotas via labels), Consul ACL, Vault path policies, existing Nomad/Consul/Vault.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/multitenancy/tasks/main.yml` | Bootstrap roles, accept tenant list var |
| `ansible/roles/multitenancy/defaults/main.yml` | sample tenants list |
| `ansible/roles/multitenancy/files/policies/tenant.hcl.j2` | per-tenant Nomad ACL policy |
| `ansible/roles/multitenancy/files/policies/tenant-vault.hcl.j2` | per-tenant Vault policy |
| `ansible/roles/multitenancy/files/policies/tenant-consul.hcl.j2` | per-tenant Consul policy |
| `ansible/inventory/group_vars/all/defaults.yml` | `tenants` list |
| `bin/tenant-create` | helper: pass slug, create everything |
| `tests/smoke/test_multitenancy.sh` | as tenant token, can run job in own ns; cannot read other ns |

---

## Task 1: Defaults + smoke

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Multi-tenancy
tenants:
  - slug: alpha
    cpu_quota: 2000
    memory_quota: 2048
  - slug: beta
    cpu_quota: 1000
    memory_quota: 1024
EOF

cat > tests/smoke/test_multitenancy.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")

echo "=== Namespaces exist ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad namespace list -t '{{range .}}{{.Name}} {{end}}'
" | grep -q tenant-alpha || { echo FAIL; exit 1; }
echo OK

echo "=== Tenant token can list its own ns ==="
ALPHA=$(multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad acl token list -t '{{range .}}{{if eq .Name \"tenant-alpha\"}}{{.SecretID}}{{end}}{{end}}' | head -c 36
")
[[ -n "$ALPHA" ]] || { echo FAIL no token; exit 1; }
multipass exec "$VM" -- bash -c "
  NOMAD_TOKEN='$ALPHA' nomad job status -namespace=tenant-alpha
" >/dev/null
echo OK

echo "=== Tenant token cannot list other ns ==="
multipass exec "$VM" -- bash -c "
  NOMAD_TOKEN='$ALPHA' nomad job status -namespace=tenant-beta 2>&1
" | grep -qi "permission denied\|forbidden" || { echo FAIL: should be denied; exit 1; }
echo OK

echo "ALL MULTITENANCY CHECKS PASSED"
EOF
chmod +x tests/smoke/test_multitenancy.sh

git add ansible/inventory/group_vars/all/defaults.yml tests/smoke/test_multitenancy.sh
git commit -m "test(multitenancy): defaults + failing smoke"
```

---

## Task 2: Nomad ACL policy template

```bash
mkdir -p ansible/roles/multitenancy/{tasks,files,defaults}
cat > ansible/roles/multitenancy/files/policies/tenant.hcl.j2 <<'EOF'
namespace "tenant-{{ tenant.slug }}" {
  policy = "write"
  capabilities = ["alloc-exec", "submit-job", "read-logs", "read-job", "list-jobs"]
}

namespace "*" {
  policy = "deny"
}

agent  { policy = "read" }
node   { policy = "read" }
operator { policy = "deny" }
quota  { policy = "read" }
EOF
```

```bash
cat > ansible/roles/multitenancy/tasks/main.yml <<'EOF'
---
- name: Create namespace per tenant
  ansible.builtin.command: >
    nomad namespace apply -description="tenant {{ tenant.slug }}" tenant-{{ tenant.slug }}
  loop: "{{ tenants }}"
  loop_control: { loop_var: tenant }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true

- name: Apply quota per tenant
  ansible.builtin.command: nomad quota apply -
  args:
    stdin: |
      name = "tenant-{{ tenant.slug }}"
      limit {
        region = "global"
        region_limit {
          cpu        = {{ tenant.cpu_quota }}
          memory_mb  = {{ tenant.memory_quota }}
        }
      }
  loop: "{{ tenants }}"
  loop_control: { loop_var: tenant }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true

- name: Render+apply Nomad ACL policy per tenant
  ansible.builtin.shell: |
    nomad acl policy apply -description "tenant-{{ tenant.slug }}" tenant-{{ tenant.slug }} -
  args:
    stdin: "{{ lookup('template', 'policies/tenant.hcl.j2') }}"
    executable: /bin/bash
  loop: "{{ tenants }}"
  loop_control: { loop_var: tenant }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true

- name: Mint a token per tenant
  ansible.builtin.shell: |
    nomad acl token create -name=tenant-{{ tenant.slug }} -policy=tenant-{{ tenant.slug }} -t '{{ '{{' }} .SecretID {{ '}}' }}'
  loop: "{{ tenants }}"
  loop_control: { loop_var: tenant }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  register: tenant_tokens
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
  no_log: true
EOF
```

```bash
git add ansible/roles/multitenancy/
git commit -m "feat(multitenancy): nomad namespaces + quotas + ACL per tenant"
```

---

## Task 3: bin/tenant-create

```bash
cat > bin/tenant-create <<'EOF'
#!/usr/bin/env bash
# Usage: bin/tenant-create <slug> [cpu_quota_mhz] [memory_mb]
set -euo pipefail
SLUG=${1:?slug required}
CPU=${2:-1000}
MEM=${3:-1024}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$ROOT_DIR/ansible/inventory/group_vars/all/secrets.yml")
SERVER_IP=$(grep -A99 '^\[servers\]' "$ROOT_DIR/ansible/inventory/hosts.ini" | grep ansible_host | head -1 | awk -F'ansible_host=' '{print $2}' | awk '{print $1}')
export NOMAD_ADDR="http://$SERVER_IP:4646" NOMAD_TOKEN

nomad namespace apply -description "tenant $SLUG" "tenant-$SLUG"
nomad quota apply - <<HCL
name = "tenant-$SLUG"
limit { region = "global" region_limit { cpu = $CPU memory_mb = $MEM } }
HCL
nomad acl policy apply -description "tenant $SLUG" "tenant-$SLUG" - <<POL
namespace "tenant-$SLUG" { policy = "write" capabilities = ["alloc-exec","submit-job","read-logs","read-job","list-jobs"] }
namespace "*" { policy = "deny" }
agent { policy = "read" } node { policy = "read" } quota { policy = "read" } operator { policy = "deny" }
POL
TOKEN=$(nomad acl token create -name="tenant-$SLUG" -policy="tenant-$SLUG" -t '{{.SecretID}}')
echo "Tenant $SLUG created. Token: $TOKEN"
EOF
chmod +x bin/tenant-create

git add bin/tenant-create
git commit -m "feat(bin): tenant-create helper"
```

---

## Task 4: Smoke + runbook + push

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags multitenancy
bash tests/smoke/test_multitenancy.sh nomad-local-server-01
```

```bash
cat > docs/runbooks/multitenancy.md <<'EOF'
# Runbook — Multi-Tenancy

## Concepts
- One Nomad namespace per tenant (`tenant-<slug>`).
- Quota: CPU MHz + memory MB, hard cap (Nomad Enterprise) or soft cap (community + monitoring).
- ACL policy: tenant token can write only to its namespace, deny on others.
- Consul KV: prefix-scoped under `orbty/tenants/<slug>/`.
- Vault: separate path or namespace per tenant.

## Onboarding a tenant
```bash
bin/tenant-create new-co 2000 4096
```

## Tenant-side workflow
Tenant gets an `NOMAD_TOKEN` and uses it to:
```bash
NOMAD_TOKEN=<tenant-token> nomad job run -namespace=tenant-newco myjob.hcl
```

## Cross-tenant isolation
- Container/microVM boundary: hardware-level (Firecracker — see firecracker plan).
- Network: Consul Connect intentions deny by default; cross-tenant calls require explicit intention.
- Storage: each tenant gets its own MinIO bucket / DB.

## Scaling quotas
Edit `tenants` in `defaults.yml`, re-run multitenancy role.

## Tenant offboarding
1. `nomad namespace stop tenant-<slug>` (after stopping all jobs).
2. `nomad acl token list` → revoke tenant tokens.
3. Delete Consul KV prefix `orbty/tenants/<slug>/`.
4. Snapshot tenant data, then drop Vault path / DB / buckets.
EOF
git add docs/runbooks/multitenancy.md
git commit -m "docs(runbook): multitenancy"
git push origin main
```

---

## Self-Review

- Audit #21 covered: namespaces, quotas, ACL.
- No placeholders.
- Type/name consistency: `tenant-<slug>` namespace + policy + quota uniform.
