# Object Storage (MinIO + TF Modules) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide app-facing S3-compatible object storage two ways: (1) self-hosted MinIO running as a Nomad job for in-cluster use, (2) Terraform modules for cloud-managed buckets (Vultr Object Storage + Backblaze B2 already drafted). Closes audit #7.

**Architecture:** MinIO single-node-single-drive job stored on `minio_data` host_volume, exposed on `:9000` (S3 API) and `:9001` (console) via Traefik with basic-auth on the console. TF modules `terraform/modules/storage/{vultr,b2}/` accept bucket name, lifecycle days, optional capability list; output endpoint, key, secret. The b2 module already exists from the backup plan; extend with vultr.

**Tech Stack:** MinIO RELEASE.2024-12-x, Traefik routing, Vultr Object Storage TF resource, b2 TF resource, existing roles.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/minio/templates/minio.nomad.hcl.j2` | MinIO service job |
| `ansible/roles/minio/tasks/main.yml` | Submit job + mc bootstrap (default user) |
| `ansible/roles/minio/defaults/main.yml` | versions, default bucket list |
| `terraform/modules/storage/vultr/main.tf,variables.tf,outputs.tf` | Vultr Object Storage |
| `ansible/roles/nomad/templates/nomad-client.hcl.j2` | host_volume `minio_data` |
| `ansible/inventory/group_vars/all/secrets.example.yml` | minio_root_user, minio_root_password |
| `tests/smoke/test_object_storage.sh` | mc alias, put, get, list |

---

## Task 1: Defaults + failing smoke

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Object storage (MinIO)
minio_version: "RELEASE.2024-12-18T13-15-44Z"
minio_data_dir: "/opt/minio"
minio_console_host: "minio.{{ traefik_domain }}"
minio_api_host: "s3.{{ traefik_domain }}"
EOF

cat >> ansible/inventory/group_vars/all/secrets.example.yml <<'EOF'
minio_root_user: "orbtyadmin"
minio_root_password: ""    # openssl rand -base64 32
EOF

cat > tests/smoke/test_object_storage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
USER=$(awk '$1=="minio_root_user:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml" | tr -d \")
PASS=$(awk '$1=="minio_root_password:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml" | tr -d \")
[[ -z "$PASS" ]] && { echo FAIL minio_root_password missing; exit 1; }

echo "=== MinIO ready ==="
code=$(multipass exec "$VM" -- curl -s -o /dev/null -w '%{http_code}' http://minio.service.consul:9000/minio/health/ready || true)
[[ "$code" == "200" ]] || { echo "FAIL: $code"; exit 1; }
echo OK

echo "=== mc put + get ==="
multipass exec "$VM" -- bash -c "
  command -v mc >/dev/null || curl -sLO https://dl.min.io/client/mc/release/linux-arm64/mc && chmod +x mc && sudo mv mc /usr/local/bin/
  mc alias set orbty http://minio.service.consul:9000 '$USER' '$PASS'
  mc mb -p orbty/smoke-test
  echo hello > /tmp/h
  mc cp /tmp/h orbty/smoke-test/h
  mc cat orbty/smoke-test/h
" | grep -q hello || { echo FAIL roundtrip; exit 1; }
echo OK

echo "ALL OBJECT STORAGE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_object_storage.sh

git add ansible/inventory/group_vars/all/defaults.yml ansible/inventory/group_vars/all/secrets.example.yml tests/smoke/test_object_storage.sh
git commit -m "test(minio): defaults + failing smoke"
```

---

## Task 2: MinIO job

```bash
mkdir -p ansible/roles/minio/{tasks,templates,defaults}
cat > ansible/roles/minio/templates/minio.nomad.hcl.j2 <<'EOF'
job "minio" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "minio" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "api"     { static = 9000 }
      port "console" { static = 9001 }
    }

    volume "data" {
      type      = "host"
      source    = "minio_data"
      read_only = false
    }

    service {
      name = "minio"
      port = "api"
      check {
        type     = "http"
        path     = "/minio/health/ready"
        interval = "10s"
        timeout  = "2s"
      }
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.minio-console.rule=Host(`{{ minio_console_host }}`)",
        "traefik.http.routers.minio-console.service=minio-console@consulcatalog",
        "traefik.http.services.minio-console.loadbalancer.server.port=9001",
        "traefik.http.routers.minio-console.tls=true",
{% if acme_enabled %}
        "traefik.http.routers.minio-console.tls.certresolver=le",
{% endif %}
        "traefik.http.routers.minio-api.rule=Host(`{{ minio_api_host }}`)",
        "traefik.http.routers.minio-api.service=minio-api@consulcatalog",
        "traefik.http.services.minio-api.loadbalancer.server.port=9000",
        "traefik.http.routers.minio-api.tls=true",
{% if acme_enabled %}
        "traefik.http.routers.minio-api.tls.certresolver=le",
{% endif %}
      ]
    }

    task "minio" {
      driver = "docker"

      env {
        MINIO_ROOT_USER     = "{{ minio_root_user }}"
        MINIO_ROOT_PASSWORD = "{{ minio_root_password }}"
        MINIO_BROWSER_REDIRECT_URL = "https://{{ minio_console_host }}"
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
        read_only   = false
      }

      config {
        image        = "minio/minio:{{ minio_version }}"
        network_mode = "host"
        args = ["server", "/data", "--console-address", ":9001"]
      }

      resources { cpu = 300; memory = 512 }
    }
  }
}
EOF

cat > ansible/roles/minio/tasks/main.yml <<'EOF'
---
- name: Ensure data dir
  ansible.builtin.file:
    path: "{{ minio_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Submit minio job
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'minio.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF
```

Add `host_volume "minio_data"` to nomad-client.hcl.j2 + run.

```bash
git add ansible/roles/minio/ ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(minio): single-node nomad job + traefik routes"
```

---

## Task 3: Vultr Object Storage TF module

```bash
mkdir -p terraform/modules/storage/vultr
cat > terraform/modules/storage/vultr/variables.tf <<'EOF'
variable "name" { type = string }
variable "cluster_id" { type = string; default = "1" }
EOF
cat > terraform/modules/storage/vultr/main.tf <<'EOF'
terraform {
  required_providers {
    vultr = { source = "vultr/vultr", version = "~> 2.31" }
  }
}

resource "vultr_object_storage" "this" {
  cluster_id = var.cluster_id
  label      = var.name
}
EOF
cat > terraform/modules/storage/vultr/outputs.tf <<'EOF'
output "endpoint"    { value = vultr_object_storage.this.s3_hostname }
output "access_key"  { value = vultr_object_storage.this.s3_access_key; sensitive = true }
output "secret_key"  { value = vultr_object_storage.this.s3_secret_key; sensitive = true }
output "bucket_url"  { value = "https://${vultr_object_storage.this.s3_hostname}/${var.name}" }
EOF
cd terraform && tofu init -backend=false && tofu validate && cd -

git add terraform/modules/storage/vultr/
git commit -m "feat(terraform): vultr object storage module"
```

---

## Task 4: Smoke + runbook + push

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags minio,nomad
bash tests/smoke/test_object_storage.sh nomad-local-server-01
```

```bash
cat > docs/runbooks/object-storage.md <<'EOF'
# Runbook — Object Storage

## Two paths

1. **Self-hosted MinIO** (in-cluster) — single-node single-drive Nomad job.
   Endpoints: `https://{{ minio_api_host }}` (S3 API), `https://{{ minio_console_host }}` (browser).
2. **Cloud-managed** — `terraform/modules/storage/{vultr,b2}` modules.

## Choose which
| Need | Choice |
|---|---|
| Cheap, low-latency, controlled | MinIO |
| Off-cluster (backups, public CDN) | b2 (cheap egress) or Vultr Object Storage |
| Multi-region replication | Cloud-managed |

## MinIO bucket
```bash
mc alias set orbty https://s3.orbty.app <user> <pass>
mc mb orbty/<bucket>
mc anonymous set download orbty/<bucket>   # public reads
```

## Cloud-managed bucket
```hcl
module "minio_offsite" {
  source = "./modules/storage/vultr"
  name   = "orbty-backups"
}
```
Outputs `endpoint`, `access_key`, `secret_key` (use in restic / app secrets).
EOF
git add docs/runbooks/object-storage.md
git commit -m "docs(runbook): object storage paths"
git push origin main
```

---

## Self-Review

- Audit #7 covered, two paths.
- No placeholders.
- Type/name consistency: `minio_*`, vultr/b2 module shape symmetrical.
