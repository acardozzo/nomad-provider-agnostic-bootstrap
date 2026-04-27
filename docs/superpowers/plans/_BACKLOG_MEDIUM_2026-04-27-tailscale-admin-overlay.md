# Tailscale Admin Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install Tailscale on every cluster node so admin access (SSH, Nomad UI, Consul UI, Grafana) goes over a zero-trust mesh, eliminating the need for public-IP exposure of management ports. Closes audit capability #25.

**Architecture:** `tailscale` package installed via Ansible role; node joins the tailnet using a pre-authenticated key (one per node, ephemeral). Tailscale ACLs (managed in Tailscale admin UI) restrict which devices can reach which ports. UFW updated to drop public access to management ports (4646, 8500, 3000) — they're only reachable over `100.x.y.z` Tailscale IPs.

**Tech Stack:** Tailscale 1.74+, existing UFW role, existing Ansible inventory.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/tailscale/tasks/main.yml` | Install + auth + start daemon |
| `ansible/roles/tailscale/defaults/main.yml` | Auth key var, tags |
| `ansible/inventory/group_vars/all/secrets.example.yml` | Document `tailscale_authkey` |
| `ansible/roles/hardening/tasks/main.yml` | Add UFW rules limiting mgmt ports to Tailscale subnet |
| `tests/smoke/test_tailscale.sh` | Verify `tailscale status` reports Active and IP in 100.64.0.0/10 |
| `docs/runbooks/admin-access.md` | How to onboard a new operator device |

---

## Task 1: Defaults + failing smoke

```bash
mkdir -p ansible/roles/tailscale/{tasks,defaults}

cat > ansible/roles/tailscale/defaults/main.yml <<'EOF'
tailscale_authkey: ""           # set per-cluster via -e or secrets.yml
tailscale_tags: ["tag:cluster"]
tailscale_advertise_routes: []
tailscale_accept_routes: false
EOF

cat >> ansible/inventory/group_vars/all/secrets.example.yml <<'EOF'
# Tailscale (https://login.tailscale.com/admin/settings/keys → Generate Auth Key)
tailscale_authkey: ""
EOF

cat > tests/smoke/test_tailscale.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
echo "=== tailscale status active on $VM ==="
out=$(multipass exec "$VM" -- sudo tailscale status 2>&1 || true)
echo "$out" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || { echo "FAIL: tailscale not up: $out"; exit 1; }
echo OK
echo "=== tailscale IPv4 in CGNAT range ==="
ip=$(multipass exec "$VM" -- sudo tailscale ip --4)
[[ "$ip" =~ ^100\. ]] || { echo "FAIL: ip $ip not in 100.x"; exit 1; }
echo "OK ($ip)"
echo "=== ssh to peer over tailscale ==="
peer_ip=$(multipass exec "$VM" -- sudo tailscale status --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((p['TailscaleIPs'][0] for p in d.get('Peer',{}).values() if p.get('TailscaleIPs')), ''))")
[[ -n "$peer_ip" ]] || { echo "FAIL no peer"; exit 1; }
multipass exec "$VM" -- bash -c "timeout 5 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@$peer_ip 'echo hello via ts'" 2>&1 | grep -q "hello via ts" || { echo "FAIL: ssh over ts"; exit 1; }
echo OK
echo "ALL TAILSCALE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_tailscale.sh

git add ansible/roles/tailscale/defaults/main.yml ansible/inventory/group_vars/all/secrets.example.yml tests/smoke/test_tailscale.sh
git commit -m "test(tailscale): defaults + failing smoke"
```

---

## Task 2: Install role

```bash
cat > ansible/roles/tailscale/tasks/main.yml <<'EOF'
---
- name: Add tailscale GPG key
  ansible.builtin.get_url:
    url: https://pkgs.tailscale.com/stable/ubuntu/{{ ansible_distribution_release }}.noarmor.gpg
    dest: /usr/share/keyrings/tailscale-archive-keyring.gpg
    mode: "0644"

- name: Add tailscale apt repo
  ansible.builtin.copy:
    dest: /etc/apt/sources.list.d/tailscale.list
    content: "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu {{ ansible_distribution_release }} main\n"
    mode: "0644"

- name: Install tailscale
  ansible.builtin.apt:
    name: tailscale
    update_cache: true
    state: present

- name: Enable IP forwarding (required for subnet routes if used)
  ansible.posix.sysctl:
    name: "{{ item }}"
    value: "1"
    sysctl_set: true
    state: present
    reload: true
  loop:
    - net.ipv4.ip_forward
    - net.ipv6.conf.all.forwarding
  when: tailscale_advertise_routes | length > 0

- name: Start tailscaled
  ansible.builtin.systemd:
    name: tailscaled
    state: started
    enabled: true

- name: Bring tailscale up (auth)
  ansible.builtin.command:
    cmd: >
      tailscale up
      --authkey={{ tailscale_authkey }}
      --hostname={{ inventory_hostname }}
      --advertise-tags={{ tailscale_tags | join(',') }}
      {% if tailscale_advertise_routes %}--advertise-routes={{ tailscale_advertise_routes | join(',') }}{% endif %}
      {% if tailscale_accept_routes %}--accept-routes{% endif %}
      --reset
  when: tailscale_authkey != ''
  no_log: true
  register: ts_up
  changed_when: ts_up.rc == 0
EOF

git add ansible/roles/tailscale/tasks/main.yml
git commit -m "feat(tailscale): ansible role installing daemon and joining tailnet"
```

---

## Task 3: Lock down management ports in UFW

In `ansible/roles/hardening/tasks/main.yml` (or wherever UFW rules live), add **after** the existing rule allowing 22/80/443:

```yaml
- name: Drop public access to mgmt ports (Nomad/Consul/Grafana)
  community.general.ufw:
    rule: deny
    port: "{{ item }}"
    proto: tcp
    src: 0.0.0.0/0
  loop: [4646, 8500, 3000]

- name: Allow mgmt ports from Tailscale CGNAT
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: tcp
    src: 100.64.0.0/10
  loop: [4646, 8500, 3000]
```

Commit:

```bash
git add ansible/roles/hardening/tasks/main.yml
git commit -m "feat(hardening): public-deny + tailscale-allow on mgmt ports"
```

---

## Task 4: Wire role in playbook

Append to `ansible/playbooks/bootstrap.yml`:

```yaml
- name: Tailscale overlay
  hosts: all
  become: true
  roles:
    - tailscale
```

Run:

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags tailscale,hardening
```

(Skip on local Multipass run if the authkey isn't set; Multipass already has direct LAN access. For real cloud cluster: set `tailscale_authkey` and run.)

---

## Task 5: Smoke + push

If running on cloud cluster:

```bash
bash tests/smoke/test_tailscale.sh <cloud-vm-name>
```

Expected: passes.

```bash
git push origin main
```

---

## Task 6: Runbook

```bash
cat > docs/runbooks/admin-access.md <<'EOF'
# Runbook — Admin Access (Tailscale Overlay)

## What's exposed publicly
- 22 (SSH) — until you migrate ssh to tailscale-only
- 80, 443 (Traefik HTTP/HTTPS) — public app traffic only
- All other ports — denied at UFW

## What's exposed to the tailnet
- 4646 (Nomad)
- 8500 (Consul)
- 3000 (Grafana)
- 8200 (Vault) — added by the vault plan

## Onboarding a new operator
1. Install Tailscale on their device (https://tailscale.com/download).
2. Have them join the same tailnet.
3. Tag their device `tag:operator` in Tailscale admin UI.
4. Apply ACL allowing `tag:operator` → `tag:cluster:[4646,8500,3000,8200,22]`.
5. They access the cluster via `nomad-local-server-01` etc. — tailnet DNS resolves automatically.

## Rotating the auth key
1. Tailscale admin UI → Auth keys → revoke old.
2. Generate new (re-usable, ephemeral, tag:cluster) and update `secrets.yml`.
3. New nodes use the new key; existing nodes keep their device-key.

## Migrating SSH off public
1. Confirm tailscale SSH works (`tailscale ssh root@nomad-local-server-01`).
2. Add UFW rule denying 22 from 0.0.0.0/0.
3. Allow 22 from 100.64.0.0/10 only.
EOF
git add docs/runbooks/admin-access.md
git commit -m "docs(runbook): admin access via tailscale"
git push origin main
```

---

## Self-Review

- Audit #25 covered.
- No placeholders.
- Type/name consistency: `tailscale_authkey`, `100.64.0.0/10` aligned.
