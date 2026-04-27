# Firecracker Validation Sprint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate that Nomad+Firecracker hits the cold-start, RAM, and density targets defined in ADR 0001 before committing to it as the production tenant runtime. Sprint outcome is a go/no-go decision documented in `docs/research/`.

**Architecture:** Install `firecracker-task-driver` on a single Nomad client, prepare a minimal Ubuntu rootfs and a Firecracker-compatible kernel, run a Nomad job that boots a microVM, and measure cold-start latency, idle RAM, density, and lifecycle correctness. Use the existing 5-VM Multipass cluster as the substrate (one client repurposed).

**Tech Stack:** Firecracker 1.10+, `firecracker-task-driver` (community), bash + python for measurements, existing Nomad/Consul cluster.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/firecracker/tasks/main.yml` | Install Firecracker binary + KVM kernel module check + driver |
| `ansible/roles/firecracker/files/firecracker-task-driver` | The driver binary (downloaded by tasks) |
| `ansible/roles/firecracker/templates/nomad-plugin.hcl.j2` | Nomad client `plugin "firecracker-task-driver"` block |
| `firecracker/rootfs/build-rootfs.sh` | Builds an Ubuntu minimal ext4 rootfs (~30MB) |
| `firecracker/rootfs/Dockerfile` | Used to extract a clean rootfs from `ubuntu:24.04` |
| `firecracker/jobs/test-microvm.nomad.hcl` | Nomad job: `task driver = "firecracker-task-driver"`, mounts rootfs, boots, runs `sleep` |
| `firecracker/jobs/whoami-microvm.nomad.hcl` | Real-app job: serves HTTP via Firecracker microVM |
| `firecracker/measure/cold-start.sh` | Measures end-to-end cold start (job submit → first 200 OK) |
| `firecracker/measure/density.sh` | Schedules N microVMs and reports OOM threshold |
| `firecracker/measure/lifecycle.sh` | Tests stop/restart/destroy paths |
| `docs/research/2026-04-27-firecracker-validation-results.md` | Final report with measured numbers + go/no-go |

---

## Pre-flight

- [ ] **Step 0: Confirm cluster** + working tree

```bash
cd /Users/ailtoncardozo/src/nomad-provider-agnostic-bootstrap
git status
multipass list | grep Running | wc -l
```

Expected: clean tree; ≥1 Multipass client running.

- [ ] **Step 1: KVM check inside the target client VM**

```bash
multipass exec nomad-local-client-01 -- bash -c "
  test -e /dev/kvm && echo 'KVM device present' || echo 'NO KVM'
  lsmod | grep -E 'kvm|vmx|svm' || echo 'no kvm modules loaded'
"
```

If `NO KVM`: Multipass uses macOS Virtualization framework which may or may not expose nested KVM. If absent, stop here and run the validation on a real Linux host (cloud VM with `nested=1` enabled). For Vultr/Linode, baremetal plans support nested KVM; standard cloud VMs typically do not.

If KVM is missing, document this as the first finding and propose: "Validation must move to a baremetal host. Submit a $50/month baremetal plan as a one-week experiment."

---

## Task 1: Failing smoke

- [ ] **Step 1: Write smoke**

```bash
cat > tests/smoke/test_firecracker.sh <<'EOF'
#!/usr/bin/env bash
# Verifies Firecracker driver loaded in Nomad and a microVM boots.
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <client-vm>" >&2; exit 64; fi
VM="$1"

echo "=== firecracker binary present ==="
multipass exec "$VM" -- which firecracker || { echo "FAIL: firecracker missing"; exit 1; }
echo "OK"

echo "=== KVM device readable by nomad ==="
multipass exec "$VM" -- bash -c "stat -c '%a %U' /dev/kvm" || { echo "FAIL"; exit 1; }
echo "OK"

echo "=== Nomad knows the driver ==="
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad node status -self -verbose 2>&1 | grep firecracker
" | grep -q firecracker || { echo "FAIL: driver not listed"; exit 1; }
echo "OK"

echo "=== microVM job runs and reports healthy ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status test-microvm 2>&1 | head -3
" | grep -q running || { echo "FAIL: test-microvm not running"; exit 1; }
echo "OK"

echo "ALL FIRECRACKER CHECKS PASSED"
EOF
chmod +x tests/smoke/test_firecracker.sh
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/smoke/test_firecracker.sh nomad-local-client-01
```

Expected: FAIL on `firecracker missing`.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/test_firecracker.sh
git commit -m "test(firecracker): failing smoke for driver + microVM boot"
```

---

## Task 2: Ansible role to install Firecracker + driver

**Files:**
- Create: `ansible/roles/firecracker/tasks/main.yml`
- Create: `ansible/roles/firecracker/templates/nomad-plugin.hcl.j2`
- Create: `ansible/roles/firecracker/defaults/main.yml`

- [ ] **Step 1: defaults**

```bash
mkdir -p ansible/roles/firecracker/{tasks,templates,defaults}
cat > ansible/roles/firecracker/defaults/main.yml <<'EOF'
firecracker_version: "1.10.1"
firecracker_driver_version: "0.5.0"
firecracker_arch: "{{ 'aarch64' if ansible_architecture == 'aarch64' else 'x86_64' }}"
firecracker_install_dir: "/usr/local/bin"
firecracker_kernel_url: "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"
firecracker_kernel_path: "/var/lib/firecracker/kernel/vmlinux.bin"
firecracker_rootfs_dir: "/var/lib/firecracker/rootfs"
EOF
```

- [ ] **Step 2: install tasks**

```bash
cat > ansible/roles/firecracker/tasks/main.yml <<'EOF'
---
- name: Verify KVM
  ansible.builtin.shell: test -e /dev/kvm
  changed_when: false

- name: Permit nomad user to use /dev/kvm
  ansible.builtin.user:
    name: nomad
    groups: kvm
    append: true

- name: Install firecracker
  ansible.builtin.get_url:
    url: "https://github.com/firecracker-microvm/firecracker/releases/download/v{{ firecracker_version }}/firecracker-v{{ firecracker_version }}-{{ firecracker_arch }}.tgz"
    dest: "/tmp/firecracker-{{ firecracker_version }}.tgz"
    mode: "0644"

- name: Extract firecracker
  ansible.builtin.unarchive:
    src: "/tmp/firecracker-{{ firecracker_version }}.tgz"
    dest: /tmp
    remote_src: true

- name: Move firecracker binary
  ansible.builtin.copy:
    src: "/tmp/release-v{{ firecracker_version }}-{{ firecracker_arch }}/firecracker-v{{ firecracker_version }}-{{ firecracker_arch }}"
    dest: "{{ firecracker_install_dir }}/firecracker"
    remote_src: true
    mode: "0755"

- name: Install firecracker-task-driver
  ansible.builtin.get_url:
    url: "https://github.com/cneira/firecracker-task-driver/releases/download/v{{ firecracker_driver_version }}/firecracker-task-driver_{{ firecracker_driver_version }}_linux_{{ firecracker_arch }}.tar.gz"
    dest: "/tmp/fc-driver.tgz"
    mode: "0644"

- name: Extract driver
  ansible.builtin.unarchive:
    src: "/tmp/fc-driver.tgz"
    dest: /opt/nomad/data/plugins
    remote_src: true
    mode: "0755"

- name: Ensure kernel + rootfs dirs
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: nomad
    group: nomad
    mode: "0755"
  loop:
    - "{{ firecracker_kernel_path | dirname }}"
    - "{{ firecracker_rootfs_dir }}"

- name: Download Firecracker reference kernel
  ansible.builtin.get_url:
    url: "{{ firecracker_kernel_url }}"
    dest: "{{ firecracker_kernel_path }}"
    owner: nomad
    group: nomad
    mode: "0644"

- name: Render Nomad plugin config
  ansible.builtin.template:
    src: nomad-plugin.hcl.j2
    dest: /etc/nomad.d/firecracker.hcl
    owner: nomad
    group: nomad
    mode: "0640"
  notify: Restart nomad
EOF
```

- [ ] **Step 3: plugin template**

```bash
cat > ansible/roles/firecracker/templates/nomad-plugin.hcl.j2 <<'EOF'
plugin "firecracker-task-driver" {
  config {
    enabled = true
  }
}
EOF
```

- [ ] **Step 4: Wire role in playbook**

Append to `ansible/playbooks/bootstrap.yml` under the clients block (or a dedicated experimental playbook `firecracker.yml`):

```yaml
- name: Firecracker validation
  hosts: clients
  become: true
  roles:
    - firecracker
```

- [ ] **Step 5: Run on a single client**

```bash
ansible-playbook -i ansible/inventory/hosts.ini -l nomad-local-client-01 \
  -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags firecracker
```

Expected: `firecracker --version` returns the pinned version.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/firecracker/
git commit -m "feat(firecracker): ansible role installing binary + nomad driver + kernel"
```

---

## Task 3: Build minimal Ubuntu rootfs

**Files:**
- Create: `firecracker/rootfs/Dockerfile`
- Create: `firecracker/rootfs/build-rootfs.sh`

- [ ] **Step 1: Dockerfile (rootfs source)**

```bash
mkdir -p firecracker/rootfs
cat > firecracker/rootfs/Dockerfile <<'EOF'
FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server iproute2 iputils-ping ca-certificates curl python3-minimal && \
    rm -rf /var/lib/apt/lists/*

RUN systemctl mask systemd-resolved.service && \
    echo "root:firecracker" | chpasswd && \
    sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    ssh-keygen -A

RUN cat > /etc/systemd/system/whoami.service <<EOL
[Unit]
Description=whoami HTTP server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server 80
Restart=always

[Install]
WantedBy=multi-user.target
EOL
RUN systemctl enable whoami.service ssh.service
EOF
```

- [ ] **Step 2: build-rootfs.sh**

```bash
cat > firecracker/rootfs/build-rootfs.sh <<'EOF'
#!/usr/bin/env bash
# Build a minimal ext4 rootfs from the Dockerfile above.
# Output: firecracker/rootfs/rootfs.ext4 (~150MB)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="$HERE/rootfs.ext4"
TAG=orbty-fc-rootfs:latest

echo "==> Building Docker image"
docker build -t "$TAG" "$HERE"

echo "==> Extracting rootfs"
CID=$(docker create "$TAG")
TMP=$(mktemp -d)
docker export "$CID" | tar -xf - -C "$TMP"
docker rm "$CID"

echo "==> Creating ext4 image (250MB)"
truncate -s 250M "$IMG"
mkfs.ext4 -F "$IMG"

MNT=$(mktemp -d)
sudo mount -o loop "$IMG" "$MNT"
sudo cp -a "$TMP/." "$MNT/"
sudo umount "$MNT"
rm -rf "$TMP" "$MNT"

echo "==> Done: $IMG ($(du -h "$IMG" | cut -f1))"
EOF
chmod +x firecracker/rootfs/build-rootfs.sh
```

- [ ] **Step 3: Run it inside the Multipass client (Docker is available there)**

```bash
multipass transfer firecracker/rootfs/build-rootfs.sh nomad-local-client-01:/tmp/build-rootfs.sh
multipass transfer firecracker/rootfs/Dockerfile nomad-local-client-01:/tmp/Dockerfile

multipass exec nomad-local-client-01 -- bash -c "
  cd /tmp && bash build-rootfs.sh && sudo mv rootfs.ext4 /var/lib/firecracker/rootfs/rootfs.ext4
"
```

Expected: rootfs.ext4 ~150-200MB in `/var/lib/firecracker/rootfs/`.

- [ ] **Step 4: Commit**

```bash
git add firecracker/rootfs/
git commit -m "feat(firecracker): minimal ubuntu 24.04 ext4 rootfs builder"
```

---

## Task 4: Test microVM job

**Files:**
- Create: `firecracker/jobs/test-microvm.nomad.hcl`

- [ ] **Step 1: Write job**

```bash
mkdir -p firecracker/jobs
cat > firecracker/jobs/test-microvm.nomad.hcl <<'EOF'
job "test-microvm" {
  datacenters = ["dc1"]
  type        = "service"

  group "vm" {
    count = 1

    constraint {
      attribute = "${attr.unique.hostname}"
      operator  = "="
      value     = "nomad-local-client-01"
    }

    network {
      mode = "host"
      port "ssh" { static = 2222 }
      port "http" { static = 8000 }
    }

    task "vm" {
      driver = "firecracker-task-driver"

      config {
        KernelImage = "/var/lib/firecracker/kernel/vmlinux.bin"
        BootDisk    = "/var/lib/firecracker/rootfs/rootfs.ext4"
        Vcpus       = 1
        Mem         = 256
        Network     = "default"
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name = "test-microvm"
        port = "http"
      }
    }
  }
}
EOF
```

- [ ] **Step 2: Submit**

```bash
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass transfer firecracker/jobs/test-microvm.nomad.hcl nomad-local-client-01:/tmp/test-microvm.nomad.hcl
multipass exec nomad-local-client-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job run /tmp/test-microvm.nomad.hcl
"
```

Expected: Deployment succeeds; alloc shows `running`.

- [ ] **Step 3: Verify with smoke**

```bash
bash tests/smoke/test_firecracker.sh nomad-local-client-01
```

Expected: `ALL FIRECRACKER CHECKS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add firecracker/jobs/test-microvm.nomad.hcl
git commit -m "feat(firecracker): test microVM nomad job"
```

---

## Task 5: Measurement scripts

**Files:**
- Create: `firecracker/measure/cold-start.sh`
- Create: `firecracker/measure/density.sh`
- Create: `firecracker/measure/lifecycle.sh`

- [ ] **Step 1: cold-start.sh**

```bash
mkdir -p firecracker/measure
cat > firecracker/measure/cold-start.sh <<'EOF'
#!/usr/bin/env bash
# Measure cold-start: submit a fresh microVM and time first HTTP 200.
# Args: <vm> <iterations>
set -euo pipefail
VM="${1:-nomad-local-client-01}"
N="${2:-10}"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")

echo "==> $N cold-start runs against $VM"
results=()
for i in $(seq 1 "$N"); do
  multipass exec "$VM" -- bash -c "
    export NOMAD_TOKEN='$NOMAD_TOKEN'
    nomad job stop -purge test-microvm >/dev/null 2>&1 || true
    sleep 2
    START=\$(date +%s%N)
    nomad job run /tmp/test-microvm.nomad.hcl >/dev/null
    until curl -sf http://127.0.0.1:8000 >/dev/null; do sleep 0.05; done
    END=\$(date +%s%N)
    echo \$(( (END - START) / 1000000 ))
  "
done | tee /tmp/cold-start-results
echo "==> p50/p95/p99 (ms)"
sort -n /tmp/cold-start-results | awk -v n="$N" 'BEGIN{ p50=int(n*0.5); p95=int(n*0.95); p99=int(n*0.99) } { a[NR]=$1 } END{ print "p50:", a[p50]; print "p95:", a[p95]; print "p99:", a[p99] }'
EOF
chmod +x firecracker/measure/cold-start.sh
```

- [ ] **Step 2: density.sh**

```bash
cat > firecracker/measure/density.sh <<'EOF'
#!/usr/bin/env bash
# Density: keep adding microVMs of size 64MB until placement fails.
set -euo pipefail
VM="${1:-nomad-local-client-01}"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  for i in \$(seq 1 50); do
    sed \"s/test-microvm/density-\$i/; s/Mem         = 256/Mem         = 64/; s/memory = 256/memory = 64/; s/static = 2222/static = 0/; s/static = 8000/static = 0/\" /tmp/test-microvm.nomad.hcl > /tmp/d.hcl
    if ! nomad job run /tmp/d.hcl 2>&1 | tail -1 | grep -q 'started successfully'; then
      echo \"OOM at \$i\"; break
    fi
    echo \"placed: \$i\"
    sleep 1
  done
  for i in \$(seq 1 50); do nomad job stop -purge density-\$i >/dev/null 2>&1; done
"
EOF
chmod +x firecracker/measure/density.sh
```

- [ ] **Step 3: lifecycle.sh**

```bash
cat > firecracker/measure/lifecycle.sh <<'EOF'
#!/usr/bin/env bash
# Lifecycle: submit, signal restart, stop, ensure clean state.
set -euo pipefail
VM="${1:-nomad-local-client-01}"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  set -e
  echo '== submit =='
  nomad job run /tmp/test-microvm.nomad.hcl
  sleep 5
  echo '== status =='
  nomad job status test-microvm | head -10
  echo '== restart =='
  ALLOC=\$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus \"running\"}}{{.ID}}{{end}}{{end}}' test-microvm | head -c 8)
  nomad alloc restart \$ALLOC
  sleep 10
  curl -sfI http://127.0.0.1:8000 | head -1
  echo '== stop =='
  nomad job stop -purge test-microvm
  sleep 3
  ! pgrep firecracker || { echo FAIL: firecracker process leaked; exit 1; }
  echo OK
"
EOF
chmod +x firecracker/measure/lifecycle.sh
```

- [ ] **Step 4: Commit**

```bash
git add firecracker/measure/
git commit -m "feat(firecracker): measurement scripts (cold-start, density, lifecycle)"
```

---

## Task 6: Run the validation

- [ ] **Step 1: cold-start (10 runs)**

```bash
bash firecracker/measure/cold-start.sh nomad-local-client-01 10
```

Record p50/p95/p99 in milliseconds.

- [ ] **Step 2: cold-start with snapshot (if driver supports)**

If `firecracker-task-driver` 0.5+ supports `Snapshot = "/path/snapshot.bin"` config, repeat the runs after taking a snapshot. If not supported, skip and document as a finding ("warm cold-start requires upstream snapshot support").

- [ ] **Step 3: density**

```bash
bash firecracker/measure/density.sh nomad-local-client-01
```

Record the OOM threshold (number of 64MB microVMs that fit on a 2GB Multipass client).

- [ ] **Step 4: lifecycle**

```bash
bash firecracker/measure/lifecycle.sh nomad-local-client-01
```

Expected: prints `OK` at end (no leaked Firecracker processes).

- [ ] **Step 5: idle RAM**

```bash
multipass exec nomad-local-client-01 -- bash -c "
  ps -eo pid,rss,cmd | grep firecracker | grep -v grep | awk '{ sum += \$2 } END { print sum/1024, \"MB\" }'
"
```

Run with 1, 5, 10 microVMs running and record per-VM overhead.

---

## Task 7: Write results doc

**Files:**
- Create: `docs/research/2026-04-27-firecracker-validation-results.md`

- [ ] **Step 1: Write report**

```bash
cat > docs/research/2026-04-27-firecracker-validation-results.md <<'EOF'
# Firecracker Validation Results

**Date:** 2026-04-27
**Substrate:** Multipass arm64 client (nomad-local-client-01) — 2 vCPU, 2GB
**Plan reference:** `_BACKLOG_2026-04-27-firecracker-validation-sprint.md`

## Targets (from ADR 0001)

| Metric | Target | Result | Pass? |
|---|---|---|---|
| Cold start (no cache) | < 500 ms | <FILL_FROM_RUN> | <Y/N> |
| Cold start (warm cache) | < 200 ms | <FILL_FROM_RUN> | <Y/N> |
| Idle RAM per microVM | < 50 MB | <FILL_FROM_RUN> | <Y/N> |
| microVMs / 2 GB client | ≥ 20 | <FILL_FROM_RUN> | <Y/N> |
| Outbound network through Traefik | works | <Y/N> | <Y/N> |
| Lifecycle (create/restart/destroy) | clean | <Y/N> | <Y/N> |

## Raw measurements

```
<paste cold-start.sh output>
<paste density.sh output>
<paste lifecycle.sh output>
```

## Findings

(Bullet list of issues encountered, driver maturity gaps, kernel
quirks, etc.)

## Decision

- ☐ GO — all targets met, proceed with port
- ☐ NO-GO — N targets failed; ADR 0001 superseded; document alternative

## Next actions

- ...
EOF
```

- [ ] **Step 2: Fill in numbers** from the runs in Task 6, then commit.

```bash
# After filling in:
git add docs/research/2026-04-27-firecracker-validation-results.md
git commit -m "docs(research): firecracker validation results"
git push origin main
```

---

## Self-Review

- ADR 0001's six measurable targets are exercised by Tasks 6.1–6.5.
- No placeholders in code; the only `<FILL_FROM_RUN>` placeholders are in
  the *results* document, where the engineer literally pastes measurements.
- Type/name consistency: `firecracker_*` defaults, `firecracker-task-driver`
  plugin name, and `test-microvm` job name are uniform.
