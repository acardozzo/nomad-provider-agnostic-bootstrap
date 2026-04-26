# Production Ingress (TLS + Hostname Routing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Traefik production-ready: Let's Encrypt ACME certificates, HTTP→HTTPS redirect, hostname-routed sample app, basic-auth-protected dashboard behind TLS, and a live smoke test.

**Architecture:** Drop the insecure dashboard port and path-based routing. Add Traefik static config flags for ACME HTTP-01 with persistent `acme.json`. Use Consul Catalog tags on the Traefik service itself to expose the dashboard host through `api@internal`, and on the whoami service for hostname-rule routing. A new bash smoke test asserts the live behavior post-bootstrap.

**Tech Stack:** Ansible, Traefik v3.x, Nomad host volumes, Consul Catalog provider, Let's Encrypt HTTP-01.

**Verification reality:** ACME issuance and TLS verification require real DNS pointing at a client node. Static checks per task validate templates, YAML, bash syntax, and var presence. The smoke test is wired in but only meaningful when the cluster is reachable via `traefik_domain`.

**Depends on:** Plan `2026-04-26-cluster-security-baseline.md` (executed first; this plan assumes `consul_bootstrap_token` is available in group_vars).

---

## File Structure

```
ansible/group_vars/all.yml                                [edit]  add ingress vars + htpasswd
ansible/playbooks/secrets.yml                             [edit]  generate dashboard password + htpasswd
ansible/roles/traefik/tasks/main.yml                      [edit]  pre-create acme.json
ansible/roles/traefik/templates/traefik.nomad.hcl.j2      [edit]  ACME, redirect, dashboard routing
ansible/roles/sample_app/templates/whoami.nomad.hcl.j2    [edit]  hostname rule, websecure, le resolver
bin/bootstrap                                             [edit]  run smoke tests post-deploy
tests/smoke/test_tls_ingress.sh                           [new]   live HTTP/HTTPS asserts
terraform/terraform.tfvars.example                        [edit]  document required values
README.md                                                 [edit]  DNS prerequisite section
docs/automation-checklist.md                              [edit]  flip TLS/DNS/hostname items
```

---

## Task 1: Declare ingress configuration surface

**Files:**
- Modify: `ansible/group_vars/all.yml`
- Modify: `terraform/terraform.tfvars.example`
- Modify: `README.md`

- [ ] **Step 1: Append to `ansible/group_vars/all.yml`**

```yaml
# Production ingress
traefik_domain: ""              # required, e.g. "example.com" — DNS A record must point at a client node
traefik_dashboard_host: ""      # required, e.g. "traefik.example.com"
acme_email: ""                  # required for Let's Encrypt registration
acme_storage_host_path: "/opt/traefik/acme"   # host directory mounted into Traefik
dashboard_basic_auth_user: "admin"
# Filled by ansible/playbooks/secrets.yml
dashboard_basic_auth_htpasswd: ""   # bcrypt $$-escaped htpasswd line
```

- [ ] **Step 2: Append to `terraform/terraform.tfvars.example`** (informational, not a TF variable)

```hcl
# Ansible ingress configuration is set in ansible/group_vars/all.yml:
#   traefik_domain          = "example.com"
#   traefik_dashboard_host  = "traefik.example.com"
#   acme_email              = "ops@example.com"
# DNS A records for both hostnames must resolve to a client node public IP.
```

- [ ] **Step 3: Append a "DNS prerequisites" section to `README.md`**

Below the existing "Quick Start" section, add:

```markdown
## DNS prerequisites for TLS

Before `bin/bootstrap`, point an A record for `traefik_domain` and
`traefik_dashboard_host` (set in `ansible/group_vars/all.yml`) at any client
node's public IP. Traefik solves Let's Encrypt HTTP-01 on port 80, so the
target host must be publicly reachable on port 80 during issuance.
```

- [ ] **Step 4: Commit**

```bash
git add ansible/group_vars/all.yml terraform/terraform.tfvars.example README.md
git commit -m "feat(ingress): declare TLS/dashboard/ACME config surface and document DNS prereqs"
```

---

## Task 2: Generate dashboard basic-auth credential in `secrets.yml`

**Files:**
- Modify: `ansible/playbooks/secrets.yml`

- [ ] **Step 1: Add the following tasks before the `Build merged secrets fact` task**

```yaml
- name: Generate dashboard password (if missing)
  ansible.builtin.shell: "openssl rand -base64 24 | tr -d '\\n'"
  register: dashboard_pw_gen
  when: existing_secrets.dashboard_basic_auth_password | default('') == ''
  changed_when: existing_secrets.dashboard_basic_auth_password | default('') == ''

- name: Compose dashboard password fact
  ansible.builtin.set_fact:
    dashboard_password: "{{ existing_secrets.dashboard_basic_auth_password | default(dashboard_pw_gen.stdout | default('')) }}"

- name: Compute htpasswd hash for Traefik basicauth
  ansible.builtin.shell: |
    htpasswd -nbB "{{ dashboard_basic_auth_user | default('admin') }}" "{{ dashboard_password }}" | sed -e 's/\$/\$\$/g'
  register: dashboard_htpasswd
  when: dashboard_password != ''
  changed_when: false
```

- [ ] **Step 2: Update the `Build merged secrets fact` task to include the new keys**

```yaml
- name: Build merged secrets fact
  ansible.builtin.set_fact:
    merged_secrets:
      consul_gossip_key: "{{ existing_secrets.consul_gossip_key | default(consul_key_gen.stdout | default('')) }}"
      nomad_gossip_key: "{{ existing_secrets.nomad_gossip_key | default(nomad_key_gen.stdout | default('')) }}"
      consul_bootstrap_token: "{{ existing_secrets.consul_bootstrap_token | default('') }}"
      nomad_bootstrap_token: "{{ existing_secrets.nomad_bootstrap_token | default('') }}"
      nomad_ingress_token: "{{ existing_secrets.nomad_ingress_token | default('') }}"
      dashboard_basic_auth_password: "{{ dashboard_password | default('') }}"
      dashboard_basic_auth_htpasswd: "{{ existing_secrets.dashboard_basic_auth_htpasswd | default(dashboard_htpasswd.stdout | default('')) }}"
```

Note on `sed`: the htpasswd output contains `$` characters that Nomad's HCL would interpret as variable interpolation. We double them once here so when the template emits them inside the job, Traefik receives the original `$`.

- [ ] **Step 3: Verify `htpasswd` is available locally**

Run: `command -v htpasswd >/dev/null && echo OK || echo "install apache2-utils / httpd-tools"`

If missing, the operator must install it before bootstrap. Document this in the README.

Add to `README.md` under the prerequisites section:

```markdown
The dashboard basic-auth hash is generated locally by `secrets.yml`, which
requires the `htpasswd` binary (`apache2-utils` on Debian/Ubuntu,
`httpd-tools` on RHEL, `httpd` on macOS via brew).
```

- [ ] **Step 4: Re-run secrets playbook locally**

Run: `ansible-playbook -i localhost, ansible/playbooks/secrets.yml`
Verify: `grep dashboard_basic_auth_htpasswd ansible/inventory/group_vars/secrets.yml | grep -v '""'`
Expected: a non-empty `$$2y$$...` line.

- [ ] **Step 5: Commit**

```bash
git add ansible/playbooks/secrets.yml README.md
git commit -m "feat(ingress): generate dashboard password and htpasswd hash idempotently"
```

---

## Task 3: Pre-create ACME storage on Traefik host

**Files:**
- Modify: `ansible/roles/traefik/tasks/main.yml`

- [ ] **Step 1: Insert the following tasks at the top of the role (before "Create Traefik jobs directory")**

```yaml
- name: Validate required ingress vars
  ansible.builtin.assert:
    that:
      - traefik_domain | length > 0
      - traefik_dashboard_host | length > 0
      - acme_email | length > 0
      - dashboard_basic_auth_htpasswd | length > 0
    fail_msg: "Set traefik_domain, traefik_dashboard_host, acme_email in ansible/group_vars/all.yml; rerun secrets.yml to populate dashboard credentials."

- name: Create Traefik ACME storage directory
  ansible.builtin.file:
    path: "{{ acme_storage_host_path }}"
    state: directory
    owner: root
    group: root
    mode: "0700"

- name: Pre-create acme.json with strict permissions
  ansible.builtin.file:
    path: "{{ acme_storage_host_path }}/acme.json"
    state: touch
    owner: root
    group: root
    mode: "0600"
    modification_time: preserve
    access_time: preserve
```

- [ ] **Step 2: YAML check**

Run: `python3 -c "import yaml; yaml.safe_load(open('ansible/roles/traefik/tasks/main.yml'))"`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/traefik/tasks/main.yml
git commit -m "feat(traefik): validate ingress vars and pre-create acme.json with 0600 perms"
```

---

## Task 4: Rewrite Traefik job — ACME, redirect, dashboard

**Files:**
- Modify: `ansible/roles/traefik/templates/traefik.nomad.hcl.j2`

- [ ] **Step 1: Replace the file contents**

```jinja
job "traefik" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "ingress" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "client"
    }

    network {
      mode = "host"

      port "http" {
        static = 80
      }

      port "https" {
        static = 443
      }
    }

    volume "acme" {
      type      = "host"
      source    = "traefik_acme"
      read_only = false
    }

    service {
      name = "traefik"
      port = "https"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.dashboard.rule=Host(`{{ traefik_dashboard_host }}`)",
        "traefik.http.routers.dashboard.entrypoints=websecure",
        "traefik.http.routers.dashboard.tls=true",
        "traefik.http.routers.dashboard.tls.certresolver=le",
        "traefik.http.routers.dashboard.service=api@internal",
        "traefik.http.routers.dashboard.middlewares=dashboard-auth",
        "traefik.http.middlewares.dashboard-auth.basicauth.users={{ dashboard_basic_auth_htpasswd }}"
      ]
    }

    task "traefik" {
      driver = "docker"

      volume_mount {
        volume      = "acme"
        destination = "/etc/traefik/acme"
        read_only   = false
      }

      env {
        CONSUL_HTTP_TOKEN = "{{ consul_bootstrap_token }}"
      }

      config {
        image        = "traefik:{{ traefik_version }}"
        network_mode = "host"

        args = [
          "--api.dashboard=true",
          "--entrypoints.web.address=:80",
          "--entrypoints.web.http.redirections.entrypoint.to=websecure",
          "--entrypoints.web.http.redirections.entrypoint.scheme=https",
          "--entrypoints.websecure.address=:443",
          "--certificatesresolvers.le.acme.email={{ acme_email }}",
          "--certificatesresolvers.le.acme.storage=/etc/traefik/acme/acme.json",
          "--certificatesresolvers.le.acme.httpchallenge=true",
          "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web",
          "--providers.consulcatalog.endpoint.address=127.0.0.1:8500",
          "--providers.consulcatalog.endpoint.token={{ consul_bootstrap_token }}",
          "--providers.consulcatalog.exposedByDefault=false"
        ]
      }

      resources {
        cpu    = 300
        memory = 256
      }
    }
  }
}
```

Key changes from the previous template:
- Removed `--api.insecure=true` (no more port 8080 dashboard).
- Removed the static `:8080` `dashboard` host port.
- Added `web` → `websecure` redirection.
- Added `le` ACME resolver with HTTP-01.
- Added `volume`/`volume_mount` for `acme.json` persistence.
- Dashboard exposed via Consul Catalog tags on the Traefik service itself, routed to `api@internal` and protected by basicauth middleware.

- [ ] **Step 2: Jinja parse**

Run: `python3 -c "import jinja2; jinja2.Environment().parse(open('ansible/roles/traefik/templates/traefik.nomad.hcl.j2').read())"`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/traefik/templates/traefik.nomad.hcl.j2
git commit -m "feat(traefik): ACME HTTP-01, HTTPS redirect, TLS-protected dashboard with basic-auth"
```

---

## Task 5: Configure Nomad client host volume for acme storage

**Files:**
- Modify: `ansible/roles/nomad/templates/nomad-client.hcl.j2`

- [ ] **Step 1: Add `host_volume` block inside `client { ... }`**

Replace the `client { ... }` block with:

```jinja
client {
  enabled = true
  servers = [{% for host in groups['servers'] %}"{{ hostvars[host].private_ip | default(hostvars[host].ansible_host) }}"{% if not loop.last %}, {% endif %}{% endfor %}]
  options = {
    "driver.raw_exec.enable" = "1"
  }

  host_volume "traefik_acme" {
    path      = "{{ acme_storage_host_path }}"
    read_only = false
  }
}
```

- [ ] **Step 2: Jinja parse**

Run: `python3 -c "import jinja2; jinja2.Environment().parse(open('ansible/roles/nomad/templates/nomad-client.hcl.j2').read())"`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(nomad): expose traefik_acme host volume on clients"
```

---

## Task 6: Hostname-route the sample app

**Files:**
- Modify: `ansible/roles/sample_app/templates/whoami.nomad.hcl.j2`

- [ ] **Step 1: Replace the `service { ... }` block with**

```jinja
    service {
      name = "whoami"
      port = "http"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.whoami.rule=Host(`{{ traefik_domain }}`) && PathPrefix(`/whoami`)",
        "traefik.http.routers.whoami.entrypoints=websecure",
        "traefik.http.routers.whoami.tls=true",
        "traefik.http.routers.whoami.tls.certresolver=le",
        "traefik.http.routers.whoami.middlewares=whoami-strip@consulcatalog",
        "traefik.http.middlewares.whoami-strip.stripprefix.prefixes=/whoami"
      ]
    }
```

- [ ] **Step 2: Jinja parse**

Run: `python3 -c "import jinja2; jinja2.Environment().parse(open('ansible/roles/sample_app/templates/whoami.nomad.hcl.j2').read())"`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/sample_app/templates/whoami.nomad.hcl.j2
git commit -m "feat(sample_app): hostname routing on websecure with le cert resolver"
```

---

## Task 7: Live TLS smoke test

**Files:**
- Create: `tests/smoke/test_tls_ingress.sh`

- [ ] **Step 1: Write `tests/smoke/test_tls_ingress.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALL="$ROOT_DIR/ansible/group_vars/all.yml"
SECRETS="$ROOT_DIR/ansible/inventory/group_vars/secrets.yml"

read_var() {
  awk -v key="$1:" '$1 == key {sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit}' "$2"
}

DOMAIN="$(read_var traefik_domain "$ALL")"
DASH="$(read_var traefik_dashboard_host "$ALL")"
DASH_USER="$(read_var dashboard_basic_auth_user "$ALL")"
DASH_PW="$(read_var dashboard_basic_auth_password "$SECRETS")"

if [[ -z "$DOMAIN" || -z "$DASH" || -z "$DASH_USER" || -z "$DASH_PW" ]]; then
  echo "FAIL: missing domain/dashboard vars in group_vars" >&2
  exit 1
fi

retry() {
  local attempts=$1 sleep_s=$2; shift 2
  local i=0
  until "$@"; do
    i=$((i+1))
    if (( i >= attempts )); then return 1; fi
    sleep "$sleep_s"
  done
}

echo "=== whoami: HTTP must redirect to HTTPS ==="
check_redirect() {
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://${DOMAIN}/whoami")
  [[ "$code" == "301" || "$code" == "308" ]]
}
retry 30 4 check_redirect || { echo "FAIL: HTTP did not redirect"; exit 1; }
echo "OK"

echo "=== whoami: HTTPS must return 200 ==="
check_200() {
  code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${DOMAIN}/whoami")
  [[ "$code" == "200" ]]
}
retry 60 5 check_200 || { echo "FAIL: HTTPS /whoami did not return 200"; exit 1; }
echo "OK"

echo "=== dashboard: HTTPS without auth must 401 ==="
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${DASH}/api/overview")
if [[ "$code" != "401" ]]; then echo "FAIL: dashboard auth open, got $code"; exit 1; fi
echo "OK ($code)"

echo "=== dashboard: HTTPS with auth must 200 ==="
code=$(curl -sk -o /dev/null -w '%{http_code}' -u "${DASH_USER}:${DASH_PW}" "https://${DASH}/api/overview")
if [[ "$code" != "200" ]]; then echo "FAIL: dashboard auth failed, got $code"; exit 1; fi
echo "OK ($code)"

echo "ALL TLS INGRESS CHECKS PASSED"
```

- [ ] **Step 2: Make executable + bash check**

Run: `chmod +x tests/smoke/test_tls_ingress.sh && bash -n tests/smoke/test_tls_ingress.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/test_tls_ingress.sh
git commit -m "test(smoke): live TLS, redirect, and dashboard-auth assertions"
```

---

## Task 8: Wire smoke tests into `bin/bootstrap`

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

echo
echo "=== Post-deploy smoke tests ==="
"$ROOT_DIR/tests/smoke/test_ingress_assets.sh"

if grep -qE '^traefik_domain: *"[^"]+"' "$ROOT_DIR/ansible/group_vars/all.yml"; then
  "$ROOT_DIR/tests/smoke/test_tls_ingress.sh"
else
  echo "Skipping TLS ingress test (traefik_domain not set)"
fi
```

- [ ] **Step 2: bash check**

Run: `bash -n bin/bootstrap && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add bin/bootstrap
git commit -m "feat(bootstrap): run ingress smoke tests after deploy"
```

---

## Task 9: Flip checklist items

**Files:**
- Modify: `docs/automation-checklist.md`

- [ ] **Step 1: Move from Not Automated Yet → Fully Automated**

```
- [x] DNS records              # operator-managed prerequisite, automation-checked at smoke
- [x] Let's Encrypt / ACME certificates
- [x] Sample app domain routing by hostname
- [x] Post-deploy smoke tests against live endpoints
```

- [ ] **Step 2: Replace the Traefik ingress entry under "Partially Automated"**

```
[x] Traefik production ingress features like TLS, DNS, and hardened middleware
```

- [ ] **Step 3: Commit**

```bash
git add docs/automation-checklist.md
git commit -m "docs: mark TLS, ACME, hostname routing, and smoke tests as automated"
```

---

## Plan-level acceptance

After all tasks pass:
- `bash -n bin/bootstrap tests/smoke/test_tls_ingress.sh` clean
- All Jinja templates parse via `python3 -c "import jinja2; ..."`
- All YAML files load via `python3 -c "import yaml; ..."`
- `git status` clean
- `ansible-playbook --syntax-check -i /tmp/stub-inv ansible/playbooks/bootstrap.yml` passes (with stub inventory)
- Re-running `ansible-playbook -i localhost, ansible/playbooks/secrets.yml` is idempotent (sha256 of `secrets.yml` unchanged)
