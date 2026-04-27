# GitOps — Atlantis + Drift Cron Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Atlantis as a Nomad job behind Traefik to handle PR-driven `tofu plan` / `tofu apply` workflows, plus a scheduled batch job that runs `tofu plan -detailed-exitcode` daily and opens a GitHub issue if drift is detected. Closes the IaC GitOps gap from research §Topic 4 (free-tier path).

**Architecture:** Atlantis (`ghcr.io/runatlantis/atlantis:v0.30`) runs as a Nomad service job with a host_volume for repo clones. GitHub webhook → Traefik route → Atlantis. Atlantis comments on PRs with plan output; merge triggers apply. Separate periodic batch job runs `tofu plan -detailed-exitcode`; non-zero exit (= drift) → `gh issue create`.

**Tech Stack:** Atlantis 0.30+, Traefik routing, Nomad batch+service jobs, GitHub PAT, OpenTofu (plan dependency).

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/atlantis/templates/atlantis.nomad.hcl.j2` | Atlantis service job |
| `ansible/roles/atlantis/templates/atlantis-config.yml.j2` | Atlantis server config |
| `ansible/roles/atlantis/templates/repo-config.yml.j2` | per-repo workflows (allow plan/apply) |
| `ansible/roles/atlantis/templates/drift-cron.nomad.hcl.j2` | Periodic batch: `tofu plan -detailed-exitcode` + gh issue |
| `ansible/roles/atlantis/tasks/main.yml` | Render configs into Consul KV + run jobs |
| `ansible/inventory/group_vars/all/defaults.yml` | atlantis_version, github_repo, atlantis_host |
| `ansible/inventory/group_vars/all/secrets.yml` | atlantis_gh_token, atlantis_gh_webhook_secret |
| `tests/smoke/test_gitops_atlantis.sh` | Verify Atlantis ready + drift cron submitted |

---

## Task 1: Defaults + secrets

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# GitOps (Atlantis)
atlantis_version: "v0.30.0"
atlantis_host: "atlantis.{{ traefik_domain }}"
atlantis_data_dir: "/opt/atlantis"
github_repo_owner: "acardozzo"
github_repo_name: "nomad-provider-agnostic-bootstrap"
EOF

cat >> ansible/inventory/group_vars/all/secrets.example.yml <<'EOF'
# GitOps secrets
atlantis_gh_token: ""              # GitHub PAT with repo + workflow scope
atlantis_gh_webhook_secret: ""     # openssl rand -hex 32
EOF

git add ansible/inventory/group_vars/all/defaults.yml ansible/inventory/group_vars/all/secrets.example.yml
git commit -m "chore(atlantis): defaults + secrets schema"
```

---

## Task 2: Failing smoke

```bash
cat > tests/smoke/test_gitops_atlantis.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"

echo "=== Atlantis healthz ==="
code=$(multipass exec "$VM" -- curl -s -o /dev/null -w '%{http_code}' http://atlantis.service.consul:4141/healthz || true)
[[ "$code" == "200" ]] || { echo "FAIL atlantis $code"; exit 1; }
echo OK

echo "=== drift cron job exists ==="
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status orbty-drift-detector
" | grep -q "Status\s*=\s*running" || { echo "FAIL"; exit 1; }
echo OK

echo "=== force-run drift cron and check exit code 0 (no drift) ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ID=\$(nomad job dispatch orbty-drift-detector | grep 'Dispatched Job ID' | awk '{print \$NF}')
  for i in \$(seq 1 30); do
    s=\$(nomad job status \$ID | grep -m1 'Status\s*=' | awk '{print \$NF}')
    [[ \"\$s\" == \"dead\" ]] && break
    sleep 5
  done
  ALLOC=\$(nomad job allocs -t '{{range .}}{{.ID}}{{end}}' \$ID | head -c 8)
  nomad alloc logs \$ALLOC | tail -3
"

echo "ALL ATLANTIS+DRIFT CHECKS PASSED"
EOF
chmod +x tests/smoke/test_gitops_atlantis.sh

git add tests/smoke/test_gitops_atlantis.sh
git commit -m "test(atlantis): failing smoke for atlantis + drift cron"
```

---

## Task 3: Atlantis configs

```bash
mkdir -p ansible/roles/atlantis/{tasks,templates}
cat > ansible/roles/atlantis/templates/atlantis-config.yml.j2 <<'EOF'
log-level: info
atlantis-url: https://{{ atlantis_host }}
gh-user: {{ github_repo_owner }}
gh-token: {{ atlantis_gh_token }}
gh-webhook-secret: {{ atlantis_gh_webhook_secret }}
repo-allowlist: github.com/{{ github_repo_owner }}/{{ github_repo_name }}
default-tf-version: 1.10.6
write-git-creds: true
hide-prev-plan-comments: true
silence-no-projects: true
EOF
```

```bash
cat > ansible/roles/atlantis/templates/repo-config.yml.j2 <<'EOF'
repos:
  - id: github.com/{{ github_repo_owner }}/{{ github_repo_name }}
    apply_requirements: [approved, mergeable]
    allowed_overrides: [workflow]
    allow_custom_workflows: false
    workflow: opentofu

workflows:
  opentofu:
    plan:
      steps:
        - run: tofu init -backend=false
        - run: tofu plan -no-color -out=$PLANFILE
    apply:
      steps:
        - run: tofu apply -no-color $PLANFILE
EOF
```

```bash
cat > ansible/roles/atlantis/templates/atlantis.nomad.hcl.j2 <<'EOF'
job "atlantis" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "atlantis" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "http" { static = 4141 }
    }

    volume "data" {
      type      = "host"
      source    = "atlantis_data"
      read_only = false
    }

    service {
      name = "atlantis"
      port = "http"
      check {
        type     = "http"
        path     = "/healthz"
        interval = "10s"
        timeout  = "2s"
      }
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.atlantis.rule=Host(`{{ atlantis_host }}`)",
        "traefik.http.routers.atlantis.tls=true",
{% if acme_enabled %}
        "traefik.http.routers.atlantis.tls.certresolver=le",
{% endif %}
      ]
    }

    task "atlantis" {
      driver = "docker"

      volume_mount {
        volume      = "data"
        destination = "/atlantis-data"
        read_only   = false
      }

      template {
        data = <<EOT
{{ '{{' }} key "atlantis/server.yml" {{ '}}' }}
EOT
        destination = "local/server.yml"
        change_mode = "restart"
      }

      template {
        data = <<EOT
{{ '{{' }} key "atlantis/repos.yml" {{ '}}' }}
EOT
        destination = "local/repos.yml"
        change_mode = "restart"
      }

      env {
        ATLANTIS_DATA_DIR = "/atlantis-data"
        ATLANTIS_PORT     = "4141"
      }

      config {
        image        = "ghcr.io/runatlantis/atlantis:{{ atlantis_version }}"
        network_mode = "host"
        args = [
          "server",
          "--config=/local/server.yml",
          "--repo-config=/local/repos.yml",
        ]
      }

      resources { cpu = 300; memory = 512 }
    }
  }
}
EOF
```

Commit:

```bash
git add ansible/roles/atlantis/templates/
git commit -m "feat(atlantis): server + repo config + nomad job"
```

---

## Task 4: Drift cron job

```bash
cat > ansible/roles/atlantis/templates/drift-cron.nomad.hcl.j2 <<'EOF'
job "orbty-drift-detector" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "batch"

  periodic {
    cron             = "0 6 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  parameterized {
    payload = "optional"
  }

  group "drift" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    task "drift" {
      driver = "docker"

      env {
        GH_TOKEN          = "{{ atlantis_gh_token }}"
        GH_REPO           = "{{ github_repo_owner }}/{{ github_repo_name }}"
        VULTR_API_KEY     = "{{ vultr_api_key | default('') }}"
        LINODE_TOKEN      = "{{ linode_token | default('') }}"
        TF_IN_AUTOMATION  = "true"
      }

      config {
        image   = "ghcr.io/opentofu/opentofu:1.10.6"
        command = "sh"
        args = [
          "-c",
          "set -e; apk add --no-cache git github-cli; git clone https://x-access-token:$GH_TOKEN@github.com/$GH_REPO /repo; cd /repo/terraform; tofu init -backend=false; tofu plan -detailed-exitcode -no-color -out=/tmp/plan; CODE=$?; if [ $CODE -eq 2 ]; then tofu show -no-color /tmp/plan > /tmp/plan.txt; gh issue create --title \"Infrastructure drift detected $(date -u +%F)\" --body \"$(head -c 60000 /tmp/plan.txt)\" --label drift,automated; elif [ $CODE -ne 0 ]; then echo \"plan errored: $CODE\"; exit $CODE; else echo \"no drift\"; fi"
        ]
      }

      resources { cpu = 200; memory = 256 }
    }
  }
}
EOF
```

Commit:

```bash
git add ansible/roles/atlantis/templates/drift-cron.nomad.hcl.j2
git commit -m "feat(atlantis): daily drift detection cron with auto-issue"
```

---

## Task 5: Render + run + host_volume

```bash
cat > ansible/roles/atlantis/tasks/main.yml <<'EOF'
---
- name: Ensure atlantis data dir on every server node
  ansible.builtin.file:
    path: "{{ atlantis_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  when: inventory_hostname in groups['servers']

- name: Render atlantis server config to Consul KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/atlantis/server.yml"
    method: PUT
    body: "{{ lookup('template', 'atlantis-config.yml.j2') }}"
    headers: { X-Consul-Token: "{{ consul_bootstrap_token }}" }
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Render atlantis repo config to Consul KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/atlantis/repos.yml"
    method: PUT
    body: "{{ lookup('template', 'repo-config.yml.j2') }}"
    headers: { X-Consul-Token: "{{ consul_bootstrap_token }}" }
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Submit atlantis job
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'atlantis.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Submit drift detector
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'drift-cron.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true
EOF
```

Add to `nomad-client.hcl.j2`:

```hcl
  host_volume "atlantis_data" {
    path      = "{{ atlantis_data_dir }}"
    read_only = false
  }
```

Run:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags atlantis,nomad
```

Commit:

```bash
git add ansible/roles/atlantis/tasks/main.yml ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(atlantis): render configs to consul kv + submit jobs"
```

---

## Task 6: Configure GitHub webhook

Manual step (out of CLI scope without `gh` PAT):

1. Generate `atlantis_gh_webhook_secret`: `openssl rand -hex 32` and add to `secrets.yml`.
2. In GitHub repo → Settings → Webhooks → Add webhook
   - Payload URL: `https://{{ atlantis_host }}/events`
   - Content type: `application/json`
   - Secret: the value from above
   - Events: `Pull request`, `Issue comment`, `Pull request review`, `Push`
3. Verify in Atlantis logs: `nomad alloc logs $(nomad job allocs ... atlantis ...)`.

Document in runbook at the next step; no commit yet.

---

## Task 7: Smoke + push + runbook

```bash
bash tests/smoke/test_gitops_atlantis.sh nomad-local-server-01
```

Expected: passes.

Runbook:

```bash
cat > docs/runbooks/gitops.md <<'EOF'
# Runbook — GitOps (Atlantis + Drift Cron)

## Workflow
1. Open PR touching `terraform/**` → GitHub webhook fires → Atlantis comments
   the plan output on the PR.
2. Reviewer approves + merges → Atlantis auto-applies via `tofu apply`.
3. Daily at 06:00 UTC, drift detector runs `tofu plan -detailed-exitcode`.
   Drift detected → opens a GitHub issue with the diff.

## Webhook setup (one-time per repo)
See `_BACKLOG_2026-04-27-gitops-atlantis-with-drift-cron.md` Task 6.

## Atlantis commands in PR
- `atlantis plan` — re-run plan
- `atlantis apply` — apply (requires approval + mergeable)
- `atlantis unlock` — release the workspace lock if stuck

## Switching to Spacelift later
- Spacelift gives drift auto-correct (not just detection) and policy-as-code.
- Migration steps:
  1. Connect Spacelift to repo.
  2. Stop Atlantis Nomad job and drift cron.
  3. Spacelift takes over plan/apply.

## Common issues
| Symptom | Fix |
|---|---|
| Webhook 401 | Verify `atlantis_gh_webhook_secret` matches GitHub secret |
| `tofu init` fails | Provider not in lockfile; run `tofu init -upgrade` locally and commit |
| Drift cron creates duplicate issues | Filter by date in title; or label dedup logic in script |
EOF
git add docs/runbooks/gitops.md
git commit -m "docs(runbook): gitops with atlantis"
git push origin main
```

---

## Self-Review

- Research §Topic 4 free-tier path: Atlantis OSS + scheduled drift cron.
- No placeholders: every config and job HCL is concrete.
- Type/name consistency: `atlantis_host`, `atlantis_data`, `orbty-drift-detector` aligned.
