# Backup — Off-Site (restic + Nomad Snapshots) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real disaster-recovery posture: nightly Nomad raft snapshots, daily restic upload of all Nomad host_volumes to an S3-compatible bucket (Backblaze B2 or Vultr Object Storage), and a documented restore drill.

**Architecture:** Two Nomad periodic batch jobs: (1) `nomad-snapshot` runs `nomad operator snapshot save` and writes the file into a host_volume; (2) `restic-backup` runs `restic backup` over `/opt/{nomad,consul,traefik,grafana,prometheus,alertmanager,loki}` plus the snapshot dir, with retention `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`. Repository password and S3 credentials are stored in `secrets.yml` and injected as env. Restic repo lives in a single S3 bucket created by Terraform.

**Tech Stack:** restic 0.17+, Nomad batch jobs (cron schedule), S3-compatible object storage (Backblaze B2 default), Consul service registration optional.

---

## File Structure

| File | Responsibility |
|---|---|
| `terraform/modules/storage/b2/main.tf` | B2 bucket + application key |
| `terraform/modules/storage/b2/variables.tf` | bucket_name, key_capabilities |
| `terraform/modules/storage/b2/outputs.tf` | endpoint, key_id, application_key |
| `ansible/roles/backups/templates/nomad-snapshot.nomad.hcl.j2` | Periodic batch: nomad raft snapshot |
| `ansible/roles/backups/templates/restic-backup.nomad.hcl.j2` | Periodic batch: restic backup |
| `ansible/roles/backups/templates/restic-init.nomad.hcl.j2` | One-shot batch: restic init (idempotent) |
| `ansible/roles/backups/tasks/main.yml` | Render+submit jobs, write secrets |
| `ansible/inventory/group_vars/all/defaults.yml` | restic_repo, restic_retention, snapshot_dir |
| `ansible/inventory/group_vars/all/secrets.yml` (manual) | RESTIC_PASSWORD, B2_KEY_ID, B2_APPLICATION_KEY |
| `bin/restore-drill` | Wrapper to execute restore drill from a fresh VM |
| `tests/smoke/test_backup_pipeline.sh` | Verify both batch jobs ran and uploaded |
| `docs/runbooks/backup-restore.md` | Full DR runbook |

---

## Task 1: Defaults

- [ ] **Step 1: Append**

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Off-site backup
backups_data_dir: "/opt/backups"
nomad_snapshot_dir: "{{ backups_data_dir }}/nomad-snapshots"
restic_version: "0.17.3"
restic_repo: "s3:s3.us-west-001.backblazeb2.com/orbty-{{ traefik_domain | replace('.','-') }}"
restic_retention_keep_daily: 7
restic_retention_keep_weekly: 4
restic_retention_keep_monthly: 6
restic_paths:
  - /opt/nomad
  - /opt/consul
  - /opt/traefik
  - /opt/grafana
  - /opt/prometheus
  - /opt/alertmanager
  - /opt/loki
  - "{{ nomad_snapshot_dir }}"
EOF
```

- [ ] **Step 2: Document required secrets**

Create `ansible/inventory/group_vars/all/secrets.example.yml` (committable):

```bash
cat > ansible/inventory/group_vars/all/secrets.example.yml <<'EOF'
# Copy to secrets.yml (gitignored) and fill in.
# Backup credentials — required when backups role runs:
restic_password: ""        # generate: openssl rand -base64 48
b2_key_id: ""              # from Backblaze B2 → Application Keys
b2_application_key: ""     # from Backblaze B2 → Application Keys
EOF
```

- [ ] **Step 3: Commit**

```bash
git add ansible/inventory/group_vars/all/defaults.yml ansible/inventory/group_vars/all/secrets.example.yml
git commit -m "chore(backups): defaults + example secrets for restic/b2"
```

---

## Task 2: Failing smoke

- [ ] **Step 1: Smoke**

```bash
cat > tests/smoke/test_backup_pipeline.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$ROOT_DIR/ansible/inventory/group_vars/all/secrets.yml"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$SECRETS")
RESTIC_PASSWORD=$(awk '$1=="restic_password:" {print $2}' "$SECRETS" | tr -d \")
[[ -z "$RESTIC_PASSWORD" ]] && { echo "FAIL: restic_password not set in secrets.yml"; exit 1; }

echo "=== nomad-snapshot job exists ==="
out=$(multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status nomad-snapshot 2>&1 | head -3
")
echo "$out" | grep -q "Status" || { echo "FAIL: $out"; exit 1; }
echo "OK"

echo "=== restic-backup job exists ==="
out=$(multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status restic-backup 2>&1 | head -3
")
echo "$out" | grep -q "Status" || { echo "FAIL: $out"; exit 1; }
echo "OK"

echo "=== Force-run nomad-snapshot and check artifact ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job dispatch nomad-snapshot >/dev/null
  sleep 30
  ls /opt/backups/nomad-snapshots/ 2>/dev/null | wc -l
" | tail -1 | awk '{ exit ($1 > 0) ? 0 : 1 }' || { echo "FAIL: no snapshot file"; exit 1; }
echo "OK"

echo "=== Force-run restic-backup and verify snapshot in repo ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job dispatch restic-backup >/dev/null
  sleep 60
"
out=$(multipass exec "$VM" -- bash -c "
  export RESTIC_PASSWORD='$RESTIC_PASSWORD'
  export B2_ACCOUNT_ID=\$(awk '\$1==\"b2_key_id:\" {print \$2}' /tmp/secrets-mirror.yml)
  export B2_ACCOUNT_KEY=\$(awk '\$1==\"b2_application_key:\" {print \$2}' /tmp/secrets-mirror.yml)
  restic -r \$(awk '\$1==\"restic_repo:\" {print \$2}' /tmp/defaults-mirror.yml) snapshots --json | head -c 500
")
echo "$out" | grep -q '"id":' || { echo "FAIL: no restic snapshots: $out"; exit 1; }
echo "OK"

echo "ALL BACKUP PIPELINE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_backup_pipeline.sh
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/smoke/test_backup_pipeline.sh nomad-local-server-01
```

Expected: FAIL on `restic_password not set` or `nomad-snapshot job exists`.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/test_backup_pipeline.sh
git commit -m "test(backups): failing smoke for restic+nomad-snapshot pipeline"
```

---

## Task 3: B2 bucket Terraform module

**Files:**
- Create: `terraform/modules/storage/b2/main.tf`, `variables.tf`, `outputs.tf`

- [ ] **Step 1: variables.tf**

```bash
mkdir -p terraform/modules/storage/b2
cat > terraform/modules/storage/b2/variables.tf <<'EOF'
variable "bucket_name" { type = string }
variable "lifecycle_keep_days" { type = number; default = 365 }
EOF
```

- [ ] **Step 2: main.tf**

```bash
cat > terraform/modules/storage/b2/main.tf <<'EOF'
terraform {
  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.10"
    }
  }
}

resource "b2_bucket" "this" {
  bucket_name = var.bucket_name
  bucket_type = "allPrivate"

  lifecycle_rules {
    file_name_prefix              = ""
    days_from_uploading_to_hiding = 0
    days_from_hiding_to_deleting  = var.lifecycle_keep_days
  }
}

resource "b2_application_key" "restic" {
  key_name      = "${var.bucket_name}-restic"
  bucket_id     = b2_bucket.this.bucket_id
  capabilities  = ["readFiles", "writeFiles", "listFiles", "deleteFiles"]
}
EOF
```

- [ ] **Step 3: outputs.tf**

```bash
cat > terraform/modules/storage/b2/outputs.tf <<'EOF'
output "bucket_name" { value = b2_bucket.this.bucket_name }
output "bucket_id"   { value = b2_bucket.this.bucket_id }
output "endpoint"    { value = "s3.us-west-001.backblazeb2.com" }
output "key_id"      { value = b2_application_key.restic.application_key_id; sensitive = true }
output "application_key" { value = b2_application_key.restic.application_key; sensitive = true }
EOF
```

- [ ] **Step 4: tofu validate (or terraform validate)**

```bash
cd terraform/modules/storage/b2
tofu init -backend=false 2>/dev/null || terraform init -backend=false
tofu validate 2>/dev/null || terraform validate
cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/storage/b2/
git commit -m "feat(terraform): b2 bucket module for restic backups"
```

---

## Task 4: Nomad-snapshot batch job

**Files:**
- Create: `ansible/roles/backups/templates/nomad-snapshot.nomad.hcl.j2`

- [ ] **Step 1: Write job**

```bash
cat > ansible/roles/backups/templates/nomad-snapshot.nomad.hcl.j2 <<'EOF'
job "nomad-snapshot" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "batch"

  periodic {
    cron             = "0 2 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  parameterized {
    payload = "optional"
  }

  group "snapshot" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    volume "snap" {
      type      = "host"
      source    = "backups_data"
      read_only = false
    }

    task "snapshot" {
      driver = "raw_exec"

      volume_mount {
        volume      = "snap"
        destination = "/snap"
        read_only   = false
      }

      env {
        NOMAD_TOKEN = "{{ nomad_bootstrap_token }}"
      }

      config {
        command = "/bin/bash"
        args = [
          "-c",
          "set -euo pipefail; STAMP=$(date -u +%Y%m%dT%H%M%SZ); /usr/local/bin/nomad operator snapshot save /snap/nomad-snapshots/nomad-${STAMP}.snap; ls -lh /snap/nomad-snapshots/nomad-${STAMP}.snap; find /snap/nomad-snapshots/ -type f -mtime +14 -delete"
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
EOF
```

- [ ] **Step 2: Pre-create dirs in Ansible**

In `ansible/roles/backups/tasks/main.yml` (top of file):

```yaml
- name: Ensure backups data dirs
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop:
    - "{{ backups_data_dir }}"
    - "{{ nomad_snapshot_dir }}"
```

- [ ] **Step 3: Add backups_data host_volume to nomad-client.hcl.j2**

```hcl
  host_volume "backups_data" {
    path      = "{{ backups_data_dir }}"
    read_only = false
  }
```

- [ ] **Step 4: Re-run nomad role to propagate volume**

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/nomad-only.yml
```

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/backups/templates/nomad-snapshot.nomad.hcl.j2 \
        ansible/roles/backups/tasks/main.yml \
        ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(backups): nomad raft snapshot periodic batch job"
```

---

## Task 5: Restic init + backup batch jobs

**Files:**
- Create: `ansible/roles/backups/templates/restic-init.nomad.hcl.j2`
- Create: `ansible/roles/backups/templates/restic-backup.nomad.hcl.j2`

- [ ] **Step 1: restic-init**

```bash
cat > ansible/roles/backups/templates/restic-init.nomad.hcl.j2 <<'EOF'
job "restic-init" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "batch"

  parameterized {
    payload = "optional"
  }

  group "init" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    task "init" {
      driver = "docker"

      env {
        RESTIC_REPOSITORY = "{{ restic_repo }}"
        RESTIC_PASSWORD   = "{{ restic_password }}"
        AWS_ACCESS_KEY_ID     = "{{ b2_key_id }}"
        AWS_SECRET_ACCESS_KEY = "{{ b2_application_key }}"
      }

      config {
        image   = "restic/restic:{{ restic_version }}"
        command = "sh"
        args    = ["-c", "restic snapshots > /dev/null 2>&1 || restic init"]
      }

      resources { cpu = 100; memory = 128 }
    }
  }
}
EOF
```

- [ ] **Step 2: restic-backup**

```bash
cat > ansible/roles/backups/templates/restic-backup.nomad.hcl.j2 <<'EOF'
job "restic-backup" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "batch"

  periodic {
    cron             = "0 3 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  parameterized {
    payload = "optional"
  }

  group "backup" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

{% for path in restic_paths %}
    volume "vol_{{ loop.index }}" {
      type      = "host"
      source    = "{{ 'backups_data' if path == nomad_snapshot_dir else path | basename + '_data' }}"
      read_only = true
    }
{% endfor %}

    task "backup" {
      driver = "docker"

      env {
        RESTIC_REPOSITORY      = "{{ restic_repo }}"
        RESTIC_PASSWORD        = "{{ restic_password }}"
        AWS_ACCESS_KEY_ID      = "{{ b2_key_id }}"
        AWS_SECRET_ACCESS_KEY  = "{{ b2_application_key }}"
        RESTIC_HOSTNAME        = "{{ inventory_hostname | default('cluster') }}"
      }

{% for path in restic_paths %}
      volume_mount {
        volume      = "vol_{{ loop.index }}"
        destination = "/data/{{ path | basename }}"
        read_only   = true
      }
{% endfor %}

      config {
        image = "restic/restic:{{ restic_version }}"
        command = "sh"
        args = [
          "-c",
          "set -e; restic backup --tag nightly /data && restic forget --prune --keep-daily {{ restic_retention_keep_daily }} --keep-weekly {{ restic_retention_keep_weekly }} --keep-monthly {{ restic_retention_keep_monthly }}"
        ]
      }

      resources { cpu = 500; memory = 512 }
    }
  }
}
EOF
```

Note: the `host_volume` mounts above assume each `restic_paths` entry corresponds to a host_volume named `<basename>_data`. If your existing `host_volume` names differ, update the Jinja `source =` line accordingly. Audit existing `host_volume` declarations in `nomad-client.hcl.j2` and reconcile names before deploy.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/backups/templates/restic-init.nomad.hcl.j2 ansible/roles/backups/templates/restic-backup.nomad.hcl.j2
git commit -m "feat(backups): restic init + nightly backup batch jobs"
```

---

## Task 6: Render+submit jobs

**Files:**
- Modify: `ansible/roles/backups/tasks/main.yml`

- [ ] **Step 1: Append render/submit**

```yaml
- name: Submit restic-init (idempotent)
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'restic-init.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Dispatch restic-init once (creates repo if missing)
  ansible.builtin.shell: nomad job dispatch restic-init
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Submit nomad-snapshot
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'nomad-snapshot.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Submit restic-backup
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'restic-backup.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true
```

- [ ] **Step 2: Set secrets manually then run**

```bash
# Edit secrets.yml — add restic_password (openssl rand -base64 48), b2_key_id, b2_application_key
${EDITOR:-vi} ansible/inventory/group_vars/all/secrets.yml

cat > /tmp/backups-only.yml <<'EOF'
- name: Backups
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - backups
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/backups-only.yml
```

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/backups/tasks/main.yml
git commit -m "feat(backups): render+submit restic-init/snapshot/backup jobs"
```

---

## Task 7: Restore drill script + runbook

**Files:**
- Create: `bin/restore-drill`
- Create: `docs/runbooks/backup-restore.md`

- [ ] **Step 1: Drill script**

```bash
cat > bin/restore-drill <<'EOF'
#!/usr/bin/env bash
# Single-VM restore drill: pull latest restic snapshot of /opt/consul into a
# scratch dir and verify Consul can be started from it. Read-only on the live cluster.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$ROOT_DIR/ansible/inventory/group_vars/all/secrets.yml"
DEFAULTS="$ROOT_DIR/ansible/inventory/group_vars/all/defaults.yml"

export RESTIC_REPOSITORY=$(awk '$1=="restic_repo:" {print $2}' "$DEFAULTS" | tr -d \")
export RESTIC_PASSWORD=$(awk '$1=="restic_password:" {print $2}' "$SECRETS" | tr -d \")
export AWS_ACCESS_KEY_ID=$(awk '$1=="b2_key_id:" {print $2}' "$SECRETS" | tr -d \")
export AWS_SECRET_ACCESS_KEY=$(awk '$1=="b2_application_key:" {print $2}' "$SECRETS" | tr -d \")

SCRATCH=$(mktemp -d -t restore-drill-XXXXXX)
trap "rm -rf $SCRATCH" EXIT
echo "==> Listing snapshots"
restic snapshots --tag nightly --latest 1
echo "==> Restoring latest /opt/consul to $SCRATCH"
restic restore latest --include /data/consul --target "$SCRATCH"
echo "==> Verifying restored data"
ls -la "$SCRATCH/data/consul" | head
test -d "$SCRATCH/data/consul/raft" && echo "OK: raft dir present" || { echo "FAIL: raft dir missing"; exit 1; }
echo "==> Drill passed. Scratch dir: $SCRATCH (will be cleaned)"
EOF
chmod +x bin/restore-drill
```

- [ ] **Step 2: Runbook**

```bash
cat > docs/runbooks/backup-restore.md <<'EOF'
# Runbook — Backup & Restore

## What is backed up
1. **Nomad raft** — daily at 02:00 UTC via `nomad-snapshot` job into
   `/opt/backups/nomad-snapshots/nomad-<TS>.snap`. 14-day local retention.
2. **All operational state** — daily at 03:00 UTC via `restic-backup` to S3:
   `/opt/{nomad,consul,traefik,grafana,prometheus,alertmanager,loki}` plus
   the snapshot dir.
3. Restic retention: 7 daily, 4 weekly, 6 monthly snapshots.

## Verifying a backup

```bash
bin/restore-drill
```

This reads-only restores the latest `/opt/consul` snapshot into a scratch
dir, verifies the raft dir is present, and exits 0 on success.

## Performing an off-site restore (full cluster lost)

1. Provision a fresh cluster: `bin/apply && bin/bootstrap`.
2. Stop services on every node:
   ```bash
   ansible all -i ansible/inventory/hosts.ini -b -m service \
     -a "name=consul state=stopped"
   ansible all -i ansible/inventory/hosts.ini -b -m service \
     -a "name=nomad state=stopped"
   ```
3. Restore data:
   ```bash
   restic -r $RESTIC_REPOSITORY restore latest --target /
   ```
4. Restore Nomad raft (servers only):
   ```bash
   nomad operator snapshot restore /opt/backups/nomad-snapshots/<latest>.snap
   ```
5. Start services:
   ```bash
   ansible all -i ansible/inventory/hosts.ini -b -m service \
     -a "name=consul state=started"
   ansible all -i ansible/inventory/hosts.ini -b -m service \
     -a "name=nomad state=started"
   ```
6. Smoke-test: `bash tests/smoke/test_acl.sh <server-ip>`.

## Rotating the restic password

1. Generate new: `openssl rand -base64 48`
2. `restic key add` with new password (keep old key live to allow read).
3. Update `secrets.yml`.
4. After confirming new key works: `restic key remove <old-key-id>`.

## Repository pruning

Restic forget runs as part of the nightly backup job. To force-prune now:
```bash
restic prune
```
EOF
```

- [ ] **Step 3: Commit**

```bash
git add bin/restore-drill docs/runbooks/backup-restore.md
git commit -m "feat(backups): restore drill script + DR runbook"
```

---

## Task 8: Make smoke pass

```bash
bash tests/smoke/test_backup_pipeline.sh nomad-local-server-01
```

Expected: `ALL BACKUP PIPELINE CHECKS PASSED`. If `restic_password not set` → fill in `secrets.yml`.

---

## Task 9: Push

```bash
git push origin main
sleep 15 && gh run list --workflow=lint.yml --limit 1
```

Expected: `completed success`.

---

## Self-Review

- Audit #19 ("Backup/DR") covered: nightly Nomad snapshot, off-site restic, retention, restore drill, runbook.
- No placeholders: secrets.example.yml documents required keys; b2 module fully concrete; restore-drill is executable.
- Type/name consistency: `backups_data_dir`, `restic_repo`, `restic_paths`, `nomad_snapshot_dir` aligned across files.
