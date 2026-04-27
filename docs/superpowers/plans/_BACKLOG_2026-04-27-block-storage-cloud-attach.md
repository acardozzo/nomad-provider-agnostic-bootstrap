# Block Storage Cloud Attach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide cloud block storage volumes (Vultr Block Storage, Linode Block Storage) attached to specific cluster nodes and exposed to Nomad as `host_volume`s. Closes audit #8.

**Architecture:** Per-provider TF module creates a block-storage volume + attaches to a named instance. Ansible task formats (idempotent) and mounts to a stable path. New `host_volume` declared in nomad-client.hcl.j2 makes it usable by jobs.

**Tech Stack:** Vultr/Linode TF providers, ext4, systemd mount unit, Ansible.

---

## File Structure

| File | Responsibility |
|---|---|
| `terraform/modules/storage/vultr-block/{main,variables,outputs}.tf` | vultr_block_storage |
| `terraform/modules/storage/linode-block/{main,variables,outputs}.tf` | linode_volume |
| `ansible/roles/block-storage/tasks/main.yml` | format + mount |
| `ansible/roles/block-storage/defaults/main.yml` | mount paths |
| `ansible/inventory/group_vars/all/defaults.yml` | block_storage_devices map |
| `tests/smoke/test_block_storage.sh` | verify mount, write+read |

---

## Task 1: Failing smoke

```bash
cat > tests/smoke/test_block_storage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
echo "=== /opt/data is a separate filesystem ==="
multipass exec "$VM" -- bash -c "
  df -h /opt/data | tail -1 | awk '{ print \$1, \$2 }'
"
mp=$(multipass exec "$VM" -- bash -c "df --output=source /opt/data | tail -1")
[[ "$mp" == /dev/* ]] || { echo "FAIL not separate fs: $mp"; exit 1; }
echo OK

echo "=== write+read ==="
multipass exec "$VM" -- sudo bash -c "echo blockstorage > /opt/data/smoke && cat /opt/data/smoke" | grep -q blockstorage || { echo FAIL; exit 1; }
echo OK

echo "ALL BLOCK STORAGE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_block_storage.sh
git add tests/smoke/test_block_storage.sh
git commit -m "test(block-storage): failing smoke"
```

---

## Task 2: TF Vultr block module

```bash
mkdir -p terraform/modules/storage/vultr-block
cat > terraform/modules/storage/vultr-block/variables.tf <<'EOF'
variable "label"        { type = string }
variable "size_gb"      { type = number }
variable "region"       { type = string }
variable "instance_id"  { type = string }
EOF
cat > terraform/modules/storage/vultr-block/main.tf <<'EOF'
terraform {
  required_providers {
    vultr = { source = "vultr/vultr", version = "~> 2.31" }
  }
}

resource "vultr_block_storage" "this" {
  label                = var.label
  size_gb              = var.size_gb
  region               = var.region
  attached_to_instance = var.instance_id
  block_type           = "high_perf"
}
EOF
cat > terraform/modules/storage/vultr-block/outputs.tf <<'EOF'
output "id"        { value = vultr_block_storage.this.id }
output "device"    { value = "/dev/disk/by-id/virtio-${vultr_block_storage.this.id}" }
output "mount_path" { value = "/opt/data" }
EOF

git add terraform/modules/storage/vultr-block/
git commit -m "feat(terraform): vultr block storage module"
```

---

## Task 3: TF Linode block module

```bash
mkdir -p terraform/modules/storage/linode-block
cat > terraform/modules/storage/linode-block/variables.tf <<'EOF'
variable "label"      { type = string }
variable "size_gb"    { type = number }
variable "region"     { type = string }
variable "linode_id"  { type = number }
EOF
cat > terraform/modules/storage/linode-block/main.tf <<'EOF'
terraform {
  required_providers {
    linode = { source = "linode/linode", version = "~> 3.11" }
  }
}

resource "linode_volume" "this" {
  label     = var.label
  size      = var.size_gb
  region    = var.region
  linode_id = var.linode_id
}
EOF
cat > terraform/modules/storage/linode-block/outputs.tf <<'EOF'
output "id"         { value = linode_volume.this.id }
output "device"     { value = linode_volume.this.filesystem_path }
output "mount_path" { value = "/opt/data" }
EOF

git add terraform/modules/storage/linode-block/
git commit -m "feat(terraform): linode block storage module"
```

---

## Task 4: Ansible role for format + mount

```bash
mkdir -p ansible/roles/block-storage/{tasks,defaults}
cat > ansible/roles/block-storage/defaults/main.yml <<'EOF'
block_storage_devices: []
# example:
# block_storage_devices:
#   - { device: /dev/sdb, mount: /opt/data, fstype: ext4 }
EOF
cat > ansible/roles/block-storage/tasks/main.yml <<'EOF'
---
- name: Wait for device present
  ansible.builtin.wait_for:
    path: "{{ item.device }}"
    timeout: 60
  loop: "{{ block_storage_devices }}"

- name: Make filesystem (idempotent)
  community.general.filesystem:
    fstype: "{{ item.fstype | default('ext4') }}"
    dev: "{{ item.device }}"
    force: false
  loop: "{{ block_storage_devices }}"

- name: Ensure mount dir
  ansible.builtin.file:
    path: "{{ item.mount }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop: "{{ block_storage_devices }}"

- name: Mount
  ansible.posix.mount:
    src: "{{ item.device }}"
    path: "{{ item.mount }}"
    fstype: "{{ item.fstype | default('ext4') }}"
    state: mounted
    opts: defaults,noatime
  loop: "{{ block_storage_devices }}"
EOF

git add ansible/roles/block-storage/
git commit -m "feat(block-storage): format+mount role"
```

---

## Task 5: Wire host_volume

In `nomad-client.hcl.j2`:

```hcl
{% for d in block_storage_devices | default([]) %}
  host_volume "{{ d.host_volume_name | default('data') }}" {
    path      = "{{ d.mount }}"
    read_only = false
  }
{% endfor %}
```

Document usage in defaults:

```yaml
# Example to enable on a client node:
# block_storage_devices:
#   - device: /dev/sdb
#     mount: /opt/data
#     fstype: ext4
#     host_volume_name: data
```

```bash
git add ansible/roles/nomad/templates/nomad-client.hcl.j2 ansible/roles/block-storage/defaults/main.yml
git commit -m "feat(block-storage): expose mounted device as host_volume"
```

---

## Task 6: Smoke + runbook + push

(Manual: configure in Terraform `terraform.tfvars` to attach a volume, apply, then re-run Ansible bootstrap pointing the role at the device.)

```bash
cat > docs/runbooks/block-storage.md <<'EOF'
# Runbook — Block Storage

## Provisioning a new volume
1. In `terraform/main.tf` instantiate the appropriate module:
   ```hcl
   module "data_disk" {
     source       = "./modules/storage/vultr-block"
     label        = "orbty-data-1"
     size_gb      = 100
     region       = var.region
     instance_id  = module.vultr[0].instances[0].id
   }
   ```
2. `bin/apply`. Volume attaches as `/dev/disk/by-id/virtio-<id>`.
3. Add to `block_storage_devices` for the target host (group_vars or host_vars):
   ```yaml
   block_storage_devices:
     - device: /dev/disk/by-id/virtio-<id>
       mount: /opt/data
       fstype: ext4
       host_volume_name: data
   ```
4. `bin/bootstrap` re-runs Ansible; volume is formatted, mounted, exposed as Nomad `host_volume "data"`.
5. Reference in jobs:
   ```hcl
   volume "data" {
     type   = "host"
     source = "data"
   }
   ```

## Resizing
1. Update `size_gb` in TF, `bin/apply`.
2. SSH to the node: `sudo resize2fs /dev/sdb` (online).

## Detach
Stop jobs using the volume → unmount → `terraform destroy -target=...`.
EOF
git add docs/runbooks/block-storage.md
git commit -m "docs(runbook): block storage"
git push origin main
```

---

## Self-Review

- Audit #8 covered for both providers.
- No placeholders.
- Type/name consistency: `block_storage_devices`, `host_volume_name` aligned.
