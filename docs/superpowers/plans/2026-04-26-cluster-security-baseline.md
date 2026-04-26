# Cluster Security Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Consul + Nomad gossip encryption and ACL bootstrap to the Ansible flow, idempotently, with secrets persisted on the operator workstation.

**Architecture:** Introduce a pre-flight `secrets.yml` playbook that generates/loads gossip keys and bootstrap tokens into a gitignored `ansible/inventory/group_vars/secrets.yml`. Existing Consul and Nomad roles read those values from group_vars, render configs with `acl { enabled = true, default_policy = "deny" }` and `encrypt = "<key>"`, then run a one-shot ACL bootstrap on `servers[0]` guarded by token presence.

**Tech Stack:** Ansible, Consul 1.20.x, Nomad 1.10.x, bash.

**Verification reality:** The cluster is not running locally; runtime asserts must happen via `tests/smoke/*.sh` against a real deployment. Static verification per task uses `ansible-playbook --syntax-check` and `python -c "import yaml; yaml.safe_load(open(...))"`.

---

## File Structure

```
ansible/playbooks/secrets.yml                            [new]   pre-flight: generate/load secrets
ansible/inventory/group_vars/secrets.yml                 [gen]   gitignored runtime output
ansible/roles/consul/tasks/main.yml                      [edit]  add ACL bootstrap step
ansible/roles/consul/templates/consul.hcl.j2             [edit]  add encrypt + acl block
ansible/roles/nomad/tasks/main.yml                       [edit]  add ACL bootstrap step
ansible/roles/nomad/templates/nomad-server.hcl.j2        [edit]  add encrypt + acl + consul token
ansible/roles/nomad/templates/nomad-client.hcl.j2        [edit]  add encrypt + acl + consul token
ansible/roles/traefik/templates/traefik.nomad.hcl.j2     [edit]  CONSUL_HTTP_TOKEN env
ansible/roles/sample_app/tasks/main.yml                  [edit]  pass NOMAD_TOKEN to nomad job run
ansible/group_vars/all.yml                               [edit]  declare new vars (defaults to empty)
bin/bootstrap                                            [edit]  run secrets.yml before bootstrap.yml
.gitignore                                               [edit]  ignore secrets.yml + .secrets/
tests/smoke/test_acl.sh                                  [new]   asserts ACL deny without token
```

---

## Task 1: Wire `.gitignore` and group_vars surface

**Files:**
- Modify: `.gitignore`
- Modify: `ansible/group_vars/all.yml`

- [ ] **Step 1: Append to `.gitignore`**

```
ansible/inventory/group_vars/secrets.yml
ansible/inventory/.secrets/
```

- [ ] **Step 2: Append to `ansible/group_vars/all.yml`**

```yaml
# Filled by ansible/playbooks/secrets.yml — DO NOT set by hand
consul_gossip_key: ""
nomad_gossip_key: ""
consul_bootstrap_token: ""
nomad_bootstrap_token: ""
nomad_ingress_token: ""
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore ansible/group_vars/all.yml
git commit -m "chore(security): declare gossip + ACL var surface and gitignore secrets"
```

---

## Task 2: `secrets.yml` playbook — generate gossip keys and capture tokens

**Files:**
- Create: `ansible/playbooks/secrets.yml`

- [ ] **Step 1: Write `ansible/playbooks/secrets.yml`**

```yaml
---
- name: Manage cluster secrets (idempotent)
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    secrets_file: "{{ playbook_dir }}/../inventory/group_vars/secrets.yml"
    secrets_dir: "{{ playbook_dir }}/../inventory/.secrets"
  tasks:
    - name: Ensure secrets dir exists
      ansible.builtin.file:
        path: "{{ secrets_dir }}"
        state: directory
        mode: "0700"

    - name: Load existing secrets (if any)
      ansible.builtin.set_fact:
        existing_secrets: "{{ lookup('ansible.builtin.file', secrets_file, errors='ignore') | default('', true) | from_yaml | default({}, true) }}"

    - name: Generate Consul gossip key (if missing)
      ansible.builtin.shell: "openssl rand -base64 32"
      register: consul_key_gen
      when: existing_secrets.consul_gossip_key | default('') == ''
      changed_when: existing_secrets.consul_gossip_key | default('') == ''

    - name: Generate Nomad gossip key (if missing)
      ansible.builtin.shell: "openssl rand -base64 32"
      register: nomad_key_gen
      when: existing_secrets.nomad_gossip_key | default('') == ''
      changed_when: existing_secrets.nomad_gossip_key | default('') == ''

    - name: Build merged secrets fact
      ansible.builtin.set_fact:
        merged_secrets:
          consul_gossip_key: "{{ existing_secrets.consul_gossip_key | default(consul_key_gen.stdout | default('')) }}"
          nomad_gossip_key: "{{ existing_secrets.nomad_gossip_key | default(nomad_key_gen.stdout | default('')) }}"
          consul_bootstrap_token: "{{ existing_secrets.consul_bootstrap_token | default('') }}"
          nomad_bootstrap_token: "{{ existing_secrets.nomad_bootstrap_token | default('') }}"
          nomad_ingress_token: "{{ existing_secrets.nomad_ingress_token | default('') }}"

    - name: Write secrets file
      ansible.builtin.copy:
        dest: "{{ secrets_file }}"
        mode: "0600"
        content: "{{ merged_secrets | to_nice_yaml }}"
```

- [ ] **Step 2: Syntax check**

Run: `ansible-playbook --syntax-check ansible/playbooks/secrets.yml`
Expected: `playbook: ansible/playbooks/secrets.yml` with no error.

- [ ] **Step 3: Dry execute locally (no ssh) to confirm key generation**

Run: `ansible-playbook -i localhost, ansible/playbooks/secrets.yml`
Expected: `ansible/inventory/group_vars/secrets.yml` exists, mode 0600, contains non-empty `consul_gossip_key` and `nomad_gossip_key`.

Verify: `grep -E '^(consul|nomad)_gossip_key:' ansible/inventory/group_vars/secrets.yml | grep -v '""'`
Expected: two lines with non-empty values.

- [ ] **Step 4: Re-run to confirm idempotency**

Run again: `ansible-playbook -i localhost, ansible/playbooks/secrets.yml`
Expected: keys unchanged (compare hashes before/after).

```bash
sha256sum ansible/inventory/group_vars/secrets.yml > /tmp/before
ansible-playbook -i localhost, ansible/playbooks/secrets.yml
sha256sum ansible/inventory/group_vars/secrets.yml > /tmp/after
diff /tmp/before /tmp/after
```

Expected: `diff` empty.

- [ ] **Step 5: Commit**

```bash
git add ansible/playbooks/secrets.yml
git commit -m "feat(security): add secrets.yml playbook for idempotent gossip key + token storage"
```

---

## Task 3: Consul template — gossip + ACL

**Files:**
- Modify: `ansible/roles/consul/templates/consul.hcl.j2`

- [ ] **Step 1: Replace `consul.hcl.j2` contents**

```jinja
datacenter = "{{ nomad_datacenter }}"
data_dir = "{{ consul_data_dir }}"
bind_addr = "{{ hostvars[inventory_hostname].private_ip | default(ansible_host) }}"
client_addr = "0.0.0.0"
server = {{ "true" if inventory_hostname in groups['servers'] else "false" }}
{% if inventory_hostname in groups['servers'] %}
bootstrap_expect = {{ groups['servers'] | length }}
{% endif %}
retry_join = [{% for host in groups['servers'] %}"{{ hostvars[host].private_ip | default(hostvars[host].ansible_host) }}"{% if not loop.last %}, {% endif %}{% endfor %}]

encrypt = "{{ consul_gossip_key }}"

acl {
  enabled                  = true
  default_policy           = "deny"
  enable_token_persistence = true
  {% if consul_bootstrap_token %}
  tokens {
    agent   = "{{ consul_bootstrap_token }}"
    default = "{{ consul_bootstrap_token }}"
  }
  {% endif %}
}

ui_config {
  enabled = true
}
```

- [ ] **Step 2: Render-syntax check via Jinja parse**

Run:
```bash
python3 -c "import jinja2; jinja2.Environment().parse(open('ansible/roles/consul/templates/consul.hcl.j2').read())"
```
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/consul/templates/consul.hcl.j2
git commit -m "feat(consul): enable gossip encryption and ACL deny-by-default"
```

---

## Task 4: Consul role — bootstrap ACL on leader, persist token

**Files:**
- Modify: `ansible/roles/consul/tasks/main.yml`

- [ ] **Step 1: Append the following tasks to the end of `ansible/roles/consul/tasks/main.yml`**

```yaml
- name: Wait for Consul to be ready
  ansible.builtin.uri:
    url: "http://127.0.0.1:8500/v1/status/leader"
    status_code: 200
  register: consul_leader_check
  retries: 30
  delay: 2
  until: consul_leader_check.status == 200 and consul_leader_check.json | length > 2

- name: Bootstrap Consul ACL (only on first server, only if no token captured yet)
  ansible.builtin.command: consul acl bootstrap -format=json
  register: consul_acl_bootstrap
  run_once: true
  delegate_to: "{{ groups['servers'][0] }}"
  when:
    - inventory_hostname == groups['servers'][0]
    - (consul_bootstrap_token | default('')) == ''
  changed_when: consul_acl_bootstrap.rc == 0
  failed_when:
    - consul_acl_bootstrap.rc != 0
    - "'ACL bootstrap no longer allowed' not in (consul_acl_bootstrap.stderr | default(''))"

- name: Persist Consul bootstrap token to local secrets file
  ansible.builtin.lineinfile:
    path: "{{ playbook_dir }}/../inventory/group_vars/secrets.yml"
    regexp: '^consul_bootstrap_token:'
    line: "consul_bootstrap_token: \"{{ (consul_acl_bootstrap.stdout | from_json).SecretID }}\""
    mode: "0600"
  delegate_to: localhost
  run_once: true
  when:
    - consul_acl_bootstrap is defined
    - consul_acl_bootstrap is not skipped
    - consul_acl_bootstrap.stdout is defined
    - consul_acl_bootstrap.stdout | length > 0
```

- [ ] **Step 2: YAML lint**

Run: `python3 -c "import yaml; yaml.safe_load(open('ansible/roles/consul/tasks/main.yml'))"`
Expected: no output, exit 0.

- [ ] **Step 3: Syntax check the bootstrap playbook (which includes this role)**

Run: `ansible-playbook --syntax-check -i ansible/inventory/hosts.ini ansible/playbooks/bootstrap.yml || true`
Note: the inventory file does not exist before `bin/render-inventory` runs; the syntax check on the role file alone is the binding test. Acceptable failures here are inventory-not-found, NOT YAML/template errors.

Run instead, with a stub inventory:
```bash
printf "[servers]\nlocalhost\n[clients]\nlocalhost\n" > /tmp/stub-inv
ansible-playbook --syntax-check -i /tmp/stub-inv ansible/playbooks/bootstrap.yml
```
Expected: `playbook: ansible/playbooks/bootstrap.yml` with no error.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/consul/tasks/main.yml
git commit -m "feat(consul): bootstrap ACL on leader and persist token locally"
```

---

## Task 5: Nomad templates — gossip + ACL + Consul token

**Files:**
- Modify: `ansible/roles/nomad/templates/nomad-server.hcl.j2`
- Modify: `ansible/roles/nomad/templates/nomad-client.hcl.j2`

- [ ] **Step 1: Replace `nomad-server.hcl.j2` contents**

```jinja
datacenter = "{{ nomad_datacenter }}"
data_dir = "{{ nomad_data_dir }}"
bind_addr = "{{ nomad_bind_addr }}"

server {
  enabled          = true
  bootstrap_expect = {{ groups['servers'] | length }}
  encrypt          = "{{ nomad_gossip_key }}"
  server_join {
    retry_join = [{% for host in groups['servers'] %}"{{ hostvars[host].private_ip | default(hostvars[host].ansible_host) }}"{% if not loop.last %}, {% endif %}{% endfor %}]
  }
}

acl {
  enabled = true
}

advertise {
  http = "{{ hostvars[inventory_hostname].private_ip | default(ansible_host) }}"
  rpc  = "{{ hostvars[inventory_hostname].private_ip | default(ansible_host) }}"
  serf = "{{ hostvars[inventory_hostname].private_ip | default(ansible_host) }}"
}

consul {
  address = "127.0.0.1:8500"
  {% if consul_bootstrap_token %}
  token   = "{{ consul_bootstrap_token }}"
  {% endif %}
}
```

- [ ] **Step 2: Replace `nomad-client.hcl.j2` contents**

```jinja
datacenter = "{{ nomad_datacenter }}"
data_dir = "{{ nomad_data_dir }}"
bind_addr = "{{ nomad_bind_addr }}"
node_class = "client"

client {
  enabled = true
  servers = [{% for host in groups['servers'] %}"{{ hostvars[host].private_ip | default(hostvars[host].ansible_host) }}"{% if not loop.last %}, {% endif %}{% endfor %}]
  options = {
    "driver.raw_exec.enable" = "1"
  }
}

acl {
  enabled = true
}

plugin "docker" {
  config {
    allow_privileged = true
  }
}

advertise {
  http = "{{ hostvars[inventory_hostname].private_ip | default(ansible_host) }}"
  rpc  = "{{ hostvars[inventory_hostname].private_ip | default(ansible_host) }}"
  serf = "{{ hostvars[inventory_hostname].private_ip | default(ansible_host) }}"
}

consul {
  address = "127.0.0.1:8500"
  {% if consul_bootstrap_token %}
  token   = "{{ consul_bootstrap_token }}"
  {% endif %}
}
```

Note: Nomad's `encrypt` lives inside `server { ... }` in the server config; on clients, gossip is server-driven so no `encrypt` is needed at the client level.

- [ ] **Step 3: Jinja parse both templates**

Run:
```bash
python3 -c "import jinja2; e=jinja2.Environment(); e.parse(open('ansible/roles/nomad/templates/nomad-server.hcl.j2').read()); e.parse(open('ansible/roles/nomad/templates/nomad-client.hcl.j2').read())"
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/nomad/templates/nomad-server.hcl.j2 ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(nomad): enable gossip encryption, ACLs, and Consul ACL token wiring"
```

---

## Task 6: Nomad role — bootstrap ACL on leader, persist token

**Files:**
- Modify: `ansible/roles/nomad/tasks/main.yml`

- [ ] **Step 1: Append to `ansible/roles/nomad/tasks/main.yml`**

```yaml
- name: Wait for Nomad to be ready (server)
  ansible.builtin.uri:
    url: "http://127.0.0.1:4646/v1/status/leader"
    status_code: 200
  register: nomad_leader_check
  retries: 30
  delay: 2
  until: nomad_leader_check.status == 200
  when: inventory_hostname in groups['servers']

- name: Bootstrap Nomad ACL (only on first server, only if no token captured yet)
  ansible.builtin.command: nomad acl bootstrap -json
  register: nomad_acl_bootstrap
  run_once: true
  delegate_to: "{{ groups['servers'][0] }}"
  when:
    - inventory_hostname == groups['servers'][0]
    - (nomad_bootstrap_token | default('')) == ''
  changed_when: nomad_acl_bootstrap.rc == 0
  failed_when:
    - nomad_acl_bootstrap.rc != 0
    - "'No cluster leader' not in (nomad_acl_bootstrap.stderr | default(''))"
    - "'ACL bootstrap already done' not in (nomad_acl_bootstrap.stderr | default(''))"

- name: Persist Nomad bootstrap token to local secrets file
  ansible.builtin.lineinfile:
    path: "{{ playbook_dir }}/../inventory/group_vars/secrets.yml"
    regexp: '^nomad_bootstrap_token:'
    line: "nomad_bootstrap_token: \"{{ (nomad_acl_bootstrap.stdout | from_json).SecretID }}\""
    mode: "0600"
  delegate_to: localhost
  run_once: true
  when:
    - nomad_acl_bootstrap is defined
    - nomad_acl_bootstrap is not skipped
    - nomad_acl_bootstrap.stdout is defined
    - nomad_acl_bootstrap.stdout | length > 0
```

- [ ] **Step 2: YAML + syntax check**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/roles/nomad/tasks/main.yml'))"
printf "[servers]\nlocalhost\n[clients]\nlocalhost\n" > /tmp/stub-inv
ansible-playbook --syntax-check -i /tmp/stub-inv ansible/playbooks/bootstrap.yml
```
Expected: both succeed.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/nomad/tasks/main.yml
git commit -m "feat(nomad): bootstrap ACL on leader and persist token locally"
```

---

## Task 7: Wire tokens into Traefik and sample_app

**Files:**
- Modify: `ansible/roles/traefik/templates/traefik.nomad.hcl.j2`
- Modify: `ansible/roles/sample_app/tasks/main.yml`

- [ ] **Step 1: Edit `traefik.nomad.hcl.j2` — inject `CONSUL_HTTP_TOKEN` env**

Inside the `task "traefik"` block, add an `env` stanza after `config { ... }`:

```jinja
      env {
        CONSUL_HTTP_TOKEN = "{{ consul_bootstrap_token }}"
      }
```

And update the existing `args` block to authenticate the Consul Catalog provider:

```jinja
        args = [
          "--api.dashboard=true",
          "--api.insecure=true",
          "--entrypoints.web.address=:80",
          "--entrypoints.websecure.address=:443",
          "--entrypoints.traefik.address=:8080",
          "--providers.consulcatalog.endpoint.address=127.0.0.1:8500",
          "--providers.consulcatalog.endpoint.token={{ consul_bootstrap_token }}",
          "--providers.consulcatalog.exposedByDefault=false"
        ]
```

(`--api.insecure` will be removed in the production-ingress plan; we keep it here so this plan can ship independently.)

- [ ] **Step 2: Edit `ansible/roles/sample_app/tasks/main.yml` — pass NOMAD_TOKEN**

Replace the `Run whoami job` task with:

```yaml
- name: Run whoami job
  ansible.builtin.command: nomad job run /opt/nomad/jobs/whoami.nomad.hcl
  environment:
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  register: whoami_job_run
  changed_when: "'job registration successful' in whoami_job_run.stdout.lower() or 'previously registered' in whoami_job_run.stdout.lower()"
```

Apply the same `environment:` change to the Traefik role's `Run Traefik job` task in `ansible/roles/traefik/tasks/main.yml`:

```yaml
- name: Run Traefik job
  ansible.builtin.command: nomad job run /opt/nomad/jobs/traefik.nomad.hcl
  environment:
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  register: traefik_job_run
  changed_when: "'job registration successful' in traefik_job_run.stdout.lower() or 'previously registered' in traefik_job_run.stdout.lower()"
```

And the `Wait for Nomad servers to elect a leader` task:

```yaml
- name: Wait for Nomad servers to elect a leader
  ansible.builtin.command: nomad server members
  environment:
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  register: nomad_server_members
  changed_when: false
  retries: 20
  delay: 5
  until: nomad_server_members.rc == 0
```

- [ ] **Step 3: Jinja + YAML check**

Run:
```bash
python3 -c "import jinja2; jinja2.Environment().parse(open('ansible/roles/traefik/templates/traefik.nomad.hcl.j2').read())"
python3 -c "import yaml; yaml.safe_load(open('ansible/roles/sample_app/tasks/main.yml'))"
python3 -c "import yaml; yaml.safe_load(open('ansible/roles/traefik/tasks/main.yml'))"
```
Expected: all succeed.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/traefik/templates/traefik.nomad.hcl.j2 ansible/roles/sample_app/tasks/main.yml ansible/roles/traefik/tasks/main.yml
git commit -m "feat(jobs): authenticate Traefik to Consul and Nomad CLI to Nomad ACLs"
```

---

## Task 8: Wire `secrets.yml` into `bin/bootstrap`

**Files:**
- Modify: `bin/bootstrap`

- [ ] **Step 1: Replace `bin/bootstrap` contents**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/bin/render-inventory"
ansible-playbook "$ROOT_DIR/ansible/playbooks/secrets.yml"
ansible-playbook -i "$ROOT_DIR/ansible/inventory/hosts.ini" "$ROOT_DIR/ansible/playbooks/bootstrap.yml"
```

- [ ] **Step 2: Verify executable bit preserved**

Run: `test -x bin/bootstrap && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add bin/bootstrap
git commit -m "feat(bootstrap): run secrets playbook before cluster bootstrap"
```

---

## Task 9: ACL smoke test

**Files:**
- Create: `tests/smoke/test_acl.sh`

- [ ] **Step 1: Write `tests/smoke/test_acl.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage: tests/smoke/test_acl.sh <server_public_ip>
# Requires the cluster to be up. Exits non-zero on any failure.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <server_public_ip>" >&2
  exit 64
fi
HOST="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$ROOT_DIR/ansible/inventory/group_vars/secrets.yml"

if [[ ! -f "$SECRETS" ]]; then
  echo "FAIL: $SECRETS missing — run bin/bootstrap first" >&2
  exit 1
fi

CONSUL_TOKEN="$(awk -F'"' '/^consul_bootstrap_token:/ {print $2}' "$SECRETS")"
NOMAD_TOKEN="$(awk -F'"' '/^nomad_bootstrap_token:/ {print $2}' "$SECRETS")"

echo "=== Consul: unauthenticated read should be denied ==="
code=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}:8500/v1/acl/tokens" || true)
if [[ "$code" != "403" && "$code" != "401" ]]; then
  echo "FAIL: expected 401/403 from Consul without token, got $code" >&2
  exit 1
fi
echo "OK ($code)"

echo "=== Consul: authenticated read should succeed ==="
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Consul-Token: ${CONSUL_TOKEN}" "http://${HOST}:8500/v1/acl/tokens")
if [[ "$code" != "200" ]]; then
  echo "FAIL: expected 200 from Consul with token, got $code" >&2
  exit 1
fi
echo "OK ($code)"

echo "=== Nomad: unauthenticated job list should be denied ==="
code=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}:4646/v1/jobs" || true)
if [[ "$code" != "403" && "$code" != "401" ]]; then
  echo "FAIL: expected 401/403 from Nomad without token, got $code" >&2
  exit 1
fi
echo "OK ($code)"

echo "=== Nomad: authenticated job list should succeed ==="
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Nomad-Token: ${NOMAD_TOKEN}" "http://${HOST}:4646/v1/jobs")
if [[ "$code" != "200" ]]; then
  echo "FAIL: expected 200 from Nomad with token, got $code" >&2
  exit 1
fi
echo "OK ($code)"

echo "ALL ACL CHECKS PASSED"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x tests/smoke/test_acl.sh`

- [ ] **Step 3: Static check (bash -n)**

Run: `bash -n tests/smoke/test_acl.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add tests/smoke/test_acl.sh
git commit -m "test(smoke): assert ACL deny-by-default and authenticated success"
```

---

## Task 10: Update automation checklist

**Files:**
- Modify: `docs/automation-checklist.md`

- [ ] **Step 1: Move these items from Not Automated Yet → Fully Automated**

```
- [x] Consul ACL bootstrap
- [x] Nomad ACL bootstrap
```

- [ ] **Step 2: Commit**

```bash
git add docs/automation-checklist.md
git commit -m "docs: mark Consul/Nomad ACL bootstrap as automated"
```

---

## Plan-level acceptance

After all tasks pass:
- `git status` clean
- `bash -n bin/bootstrap` passes
- `ansible-playbook --syntax-check` passes for both `secrets.yml` and `bootstrap.yml` (with stub inventory)
- All Jinja templates parse
- `tests/smoke/test_acl.sh` is executable and `bash -n`-clean
- `git log --oneline` shows ten focused commits
