# Trivy Continuous Image Scanning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two-layered continuous image security scanning: (1) CI step that runs `trivy image` against any image referenced in changed Nomad job templates and fails the build on HIGH/CRITICAL CVEs without an accepted-risk annotation; (2) periodic Nomad batch job that scans every image currently scheduled in the cluster and pushes findings to a Loki stream `job=trivy`.

**Architecture:** CI: `aquasec/trivy-action` on PR. Runtime: a daily Nomad batch job runs a script that lists all unique container images via Nomad API and shells out to trivy CLI for each, emitting JSON to stdout (Promtail picks up).

**Tech Stack:** Trivy 0.56+, GitHub Actions, Nomad batch job, existing Loki+Promtail.

---

## File Structure

| File | Responsibility |
|---|---|
| `.github/workflows/trivy-scan.yml` | PR-time scan of changed images |
| `.trivyignore` | accepted-risk CVE exceptions |
| `ansible/roles/security/templates/trivy-cron.nomad.hcl.j2` | Daily cluster-wide scan |
| `ansible/roles/security/tasks/main.yml` | Submit cron job |
| `ansible/inventory/group_vars/all/defaults.yml` | trivy_version, severity threshold |
| `tests/smoke/test_trivy.sh` | Force-run cron job, assert JSON in Loki |

---

## Task 1: CI workflow

```bash
cat > .github/workflows/trivy-scan.yml <<'EOF'
name: trivy-scan

on:
  pull_request:
    paths:
      - 'ansible/roles/**/templates/*.nomad.hcl.j2'
      - 'firecracker/**'
  push:
    branches: [main]

jobs:
  scan-changed-images:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      - name: Find images in changed templates
        id: images
        run: |
          set -euo pipefail
          # Collect unique `image = "..."` references from changed .j2 templates
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            BASE_SHA=${{ github.event.pull_request.base.sha }}
          else
            BASE_SHA=$(git rev-parse HEAD~1)
          fi
          mapfile -t files < <(git diff --name-only "$BASE_SHA"...HEAD -- 'ansible/roles/**/templates/*.nomad.hcl.j2' || true)
          imgs=()
          for f in "${files[@]:-}"; do
            [ -z "$f" ] && continue
            grep -oE 'image\s*=\s*"[^"]+"' "$f" | sed -E 's/.*"(.+)".*/\1/' >> /tmp/all
          done
          sort -u /tmp/all 2>/dev/null > /tmp/uniq || true
          {
            echo 'images<<EOL'
            cat /tmp/uniq
            echo EOL
          } >> "$GITHUB_OUTPUT"

      - name: Trivy scan
        if: steps.images.outputs.images != ''
        run: |
          set -e
          while read -r img; do
            [ -z "$img" ] && continue
            # Skip jinja-templated lines (contain {{ }})
            echo "$img" | grep -q '{{' && { echo "skip: $img"; continue; }
            echo "==> trivy image $img"
            docker run --rm -v "${{ github.workspace }}/.trivyignore:/.trivyignore" \
              aquasec/trivy:0.56.2 image \
              --severity HIGH,CRITICAL --exit-code 1 --ignorefile /.trivyignore \
              --no-progress "$img"
          done <<< "${{ steps.images.outputs.images }}"
EOF
```

```bash
cat > .trivyignore <<'EOF'
# Accepted-risk CVE list. Each line: CVE-XXXX-XXXXX
# Document why and an expiry in a comment above each entry.

# Example:
# Accepted until 2026-12: not exploitable on our config
# CVE-2024-12345
EOF

git add .github/workflows/trivy-scan.yml .trivyignore
git commit -m "ci(security): trivy PR scan for changed nomad job images"
```

---

## Task 2: Failing smoke

```bash
cat > tests/smoke/test_trivy.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")

echo "=== trivy-cluster-scan job exists ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status trivy-cluster-scan
" | grep -q "Status\s*=\s*running" || { echo FAIL; exit 1; }
echo OK

echo "=== Force-run, expect json output ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ID=\$(nomad job dispatch trivy-cluster-scan | grep 'Dispatched Job ID' | awk '{print \$NF}')
  for i in \$(seq 1 60); do
    s=\$(nomad job status \$ID | grep -m1 'Status\s*=' | awk '{print \$NF}')
    [[ \"\$s\" == \"dead\" ]] && break
    sleep 5
  done
  ALLOC=\$(nomad job allocs -t '{{range .}}{{.ID}}{{end}}' \$ID | head -c 8)
  nomad alloc logs \$ALLOC | grep -c '\"VulnerabilityID\"' | tee /dev/stderr | awk '{ exit (\$1 > 0 ? 0 : 1) }'
" || { echo FAIL no findings; exit 1; }
echo OK

echo "=== Loki has trivy stream ==="
out=$(multipass exec "$VM" -- bash -c "
  curl -s -G --data-urlencode 'query={job=\"trivy\"}' --data-urlencode 'limit=1' \
    --data-urlencode 'start='\$(date -u -d '15 min ago' +%s)000000000 \
    'http://loki.service.consul:3100/loki/api/v1/query_range'
")
echo "$out" | grep -q '"resultType":"streams"' || { echo FAIL: "$out"; exit 1; }
echo OK

echo "ALL TRIVY CHECKS PASSED"
EOF
chmod +x tests/smoke/test_trivy.sh

git add tests/smoke/test_trivy.sh
git commit -m "test(trivy): failing smoke for periodic cluster scan"
```

---

## Task 3: Defaults + cron job

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Security scanning
trivy_version: "0.56.2"
trivy_severity: "HIGH,CRITICAL"
EOF
```

```bash
mkdir -p ansible/roles/security/{tasks,templates}
cat > ansible/roles/security/templates/trivy-cron.nomad.hcl.j2 <<'EOF'
job "trivy-cluster-scan" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "batch"

  periodic {
    cron             = "0 4 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  parameterized {
    payload = "optional"
  }

  group "scan" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    task "scan" {
      driver = "docker"

      env {
        NOMAD_TOKEN = "{{ nomad_bootstrap_token }}"
        SEVERITY    = "{{ trivy_severity }}"
      }

      config {
        image      = "aquasec/trivy:{{ trivy_version }}"
        entrypoint = ["sh", "-c"]
        args = [
<<-CMD
set -e
apk add --no-cache curl jq docker-cli >/dev/null
IMAGES=$(curl -sH "X-Nomad-Token: $NOMAD_TOKEN" http://127.0.0.1:4646/v1/jobs |
         jq -r '.[].ID' |
         while read j; do
           curl -sH "X-Nomad-Token: $NOMAD_TOKEN" "http://127.0.0.1:4646/v1/job/$j" |
             jq -r '.TaskGroups[].Tasks[].Config.image // empty'
         done | sort -u)
for IMG in $IMAGES; do
  echo "{\"event\":\"scan_start\",\"image\":\"$IMG\"}"
  trivy image --quiet --no-progress --severity "$SEVERITY" --format json "$IMG" \
    | jq -c --arg img "$IMG" '{event:"finding", image:$img, results:.Results}' || true
  echo "{\"event\":\"scan_end\",\"image\":\"$IMG\"}"
done
CMD
        ]
      }

      resources { cpu = 200; memory = 512 }

      service {
        name = "trivy"
        tags = ["scan"]
      }
    }
  }
}
EOF
```

```bash
cat > ansible/roles/security/tasks/main.yml <<'EOF'
---
- name: Submit trivy cron
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'trivy-cron.nomad.hcl.j2') }}"
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

Wire into bootstrap playbook:

```yaml
- name: Security scanning
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - security
```

Commit:

```bash
git add ansible/roles/security/ ansible/inventory/group_vars/all/defaults.yml
git commit -m "feat(security): trivy daily cluster scan job"
```

---

## Task 4: Smoke + push

Run monitoring (logs) plan first if not done — Promtail must be live so Loki receives `job=trivy` stream.

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags security
bash tests/smoke/test_trivy.sh nomad-local-server-01
```

Expected: passes.

```bash
git push origin main
```

---

## Task 5: Runbook

```bash
cat > docs/runbooks/security-scanning.md <<'EOF'
# Runbook — Continuous Security Scanning (Trivy)

## What runs
- **CI (`trivy-scan` workflow):** every PR that changes Nomad job templates,
  scans the referenced container images. HIGH/CRITICAL findings fail the build
  unless the CVE is in `.trivyignore`.
- **Cluster (`trivy-cluster-scan` Nomad job):** daily 04:00 UTC, scans every
  image referenced by any running job. Findings ship to Loki (`{job="trivy"}`)
  as JSON.

## Querying findings in Grafana
```
{job="trivy"} | json
```
Filter by image:
```
{job="trivy"} | json | image=~".*postgres.*"
```

## Accepting a CVE
1. Document why (ticket link, expiry date).
2. Add CVE ID to `.trivyignore` with a comment.
3. PR review: another engineer signs off the ignore.

## Triaging a high-severity finding
1. Check if it's in the data path of a tenant or system service.
2. If a fix is available upstream: bump image version in the role template, PR.
3. If no fix yet: add to `.trivyignore` with expiry date and an alert that fires when expiry approaches.

## Suppressing noise (rate-of-change)
- Pin image versions (avoid `:latest`).
- Bump deliberately, not via Renovate (which would flood PRs with scan failures).
EOF
git add docs/runbooks/security-scanning.md
git commit -m "docs(runbook): trivy continuous scanning"
git push origin main
```

---

## Self-Review

- Audit #26 covered: PR-time + runtime scanning.
- No placeholders.
- Type/name consistency: `trivy-cluster-scan` job name, `.trivyignore` path, `{job="trivy"}` Loki label.
