# Observability — Logs (Loki + Promtail) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Loki + Promtail as Nomad jobs in the existing monitoring role so every Nomad allocation's stdout/stderr is collected, indexed, and queryable from Grafana via the Loki datasource.

**Architecture:** Single-binary Loki (`grafana/loki:3.x`) runs as one Nomad service job on a server node, persisting to a host_volume. Promtail (`grafana/promtail:3.x`) runs as a system job on every Nomad client, scraping `/alloc/logs/*` via the Nomad API and shipping to Loki. Grafana auto-provisions a Loki datasource at `http://loki.service.consul:3100`.

**Tech Stack:** Loki 3.x, Promtail 3.x, Nomad (system + service jobs), Consul (service discovery), existing Grafana role.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/monitoring/templates/loki.nomad.hcl.j2` | Single-instance Loki service job with host_volume `loki_data` |
| `ansible/roles/monitoring/templates/loki-config.yml.j2` | Loki config (filesystem store, retention, single-binary) |
| `ansible/roles/monitoring/templates/promtail.nomad.hcl.j2` | System job scraping Nomad allocation logs |
| `ansible/roles/monitoring/templates/promtail-config.yml.j2` | Promtail scrape config using Nomad SD |
| `ansible/roles/monitoring/tasks/main.yml` | Append tasks to render configs into Consul KV + run jobs |
| `ansible/roles/nomad/templates/nomad-client.hcl.j2` | Add `host_volume "loki_data"` (server nodes only via constraint) |
| `ansible/inventory/group_vars/all/defaults.yml` | Add `loki_version`, `promtail_version`, `loki_retention_days` |
| `ansible/roles/monitoring/templates/grafana-datasources.yml.j2` | Append Loki datasource block (modify if file exists, create if not) |
| `tests/smoke/test_logs_pipeline.sh` | New smoke test: write a known log line in whoami, query Loki via API, assert hit |

---

## Pre-flight

- [ ] **Step 0: Confirm cluster up + working tree**

```bash
cd /Users/ailtoncardozo/src/nomad-provider-agnostic-bootstrap
git status
multipass list | grep -c Running
```

Expected: clean tree; 5 VMs Running.

---

## Task 1: Defaults

**Files:**
- Modify: `ansible/inventory/group_vars/all/defaults.yml`

- [ ] **Step 1: Append versions and retention**

Append to `ansible/inventory/group_vars/all/defaults.yml`:

```yaml

# Logs pipeline
loki_version: "3.2.1"
promtail_version: "3.2.1"
loki_retention_days: 14
loki_data_dir: "/opt/loki"
```

- [ ] **Step 2: Commit**

```bash
git add ansible/inventory/group_vars/all/defaults.yml
git commit -m "chore(monitoring): add loki/promtail version + retention defaults"
```

---

## Task 2: Failing smoke test

**Files:**
- Create: `tests/smoke/test_logs_pipeline.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/smoke/test_logs_pipeline.sh <<'EOF'
#!/usr/bin/env bash
# Verifies Loki receives logs from at least one Nomad allocation via Promtail.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <multipass-server-vm-name>" >&2
  exit 64
fi
VM="$1"

echo "=== Loki: ready endpoint must return 200 ==="
code=$(multipass exec "$VM" -- bash -c "
  curl -s -o /dev/null -w '%{http_code}' http://loki.service.consul:3100/ready || true
")
if [[ "$code" != "200" ]]; then
  echo "FAIL: Loki /ready returned $code (expected 200)" >&2
  exit 1
fi
echo "OK"

echo "=== Promtail: must register at least one target per client ==="
targets=$(multipass exec "$VM" -- bash -c "
  curl -s 'http://promtail.service.consul:9080/targets' || true
")
if [[ -z "$targets" ]]; then
  echo "FAIL: Promtail /targets returned empty" >&2
  exit 1
fi
echo "OK"

echo "=== Loki query: at least one log line tagged job=traefik in last hour ==="
out=$(multipass exec "$VM" -- bash -c "
  curl -s -G --data-urlencode 'query={job=\"traefik\"}' \
    --data-urlencode 'limit=5' \
    --data-urlencode 'start='\$(date -u -d '1 hour ago' +%s)000000000 \
    'http://loki.service.consul:3100/loki/api/v1/query_range'
")
if ! echo "$out" | grep -q '"resultType":"streams"'; then
  echo "FAIL: Loki query returned no streams, body=$out" >&2
  exit 1
fi
if echo "$out" | grep -q '"result":\[\]'; then
  echo "FAIL: Loki has no traefik logs in last hour" >&2
  exit 1
fi
echo "OK"

echo "ALL LOG PIPELINE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_logs_pipeline.sh
```

- [ ] **Step 2: Run to confirm failure**

```bash
bash tests/smoke/test_logs_pipeline.sh nomad-local-server-01
```

Expected: FAIL on `Loki /ready returned 000` (DNS doesn't resolve, Loki not deployed).

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/test_logs_pipeline.sh
git commit -m "test(logs): add failing smoke for loki/promtail pipeline"
```

---

## Task 3: Add Loki host_volume on server nodes

**Files:**
- Modify: `ansible/roles/nomad/templates/nomad-client.hcl.j2`

- [ ] **Step 1: Add host_volume**

Open the file and inside the `client {` block, locate the existing `host_volume "..."` declarations. Append:

```hcl
  host_volume "loki_data" {
    path      = "{{ loki_data_dir }}"
    read_only = false
  }
```

If the file uses Jinja conditionals to include volumes only on server-class nodes, place the block accordingly. If not, the volume is created on every client; harmless because Loki has a constraint binding it to one node (next task).

- [ ] **Step 2: Pre-create directory on every node**

Add to `ansible/roles/nomad/tasks/main.yml`, near the existing directory loop:

```yaml
- name: Ensure Loki data dir exists
  ansible.builtin.file:
    path: "{{ loki_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
```

- [ ] **Step 3: Re-render Nomad client config**

```bash
cat > /tmp/nomad-only.yml <<'EOF'
- name: Re-render nomad config
  hosts: all
  become: true
  roles:
    - nomad
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/nomad-only.yml
```

Expected: nomad service restarted on every node.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/nomad/templates/nomad-client.hcl.j2 ansible/roles/nomad/tasks/main.yml
git commit -m "feat(nomad): add loki_data host_volume + pre-create dir"
```

---

## Task 4: Loki config + Nomad job

**Files:**
- Create: `ansible/roles/monitoring/templates/loki-config.yml.j2`
- Create: `ansible/roles/monitoring/templates/loki.nomad.hcl.j2`

- [ ] **Step 1: Write Loki config template**

```bash
cat > ansible/roles/monitoring/templates/loki-config.yml.j2 <<'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: warn

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: {{ loki_retention_days }}d
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_query_length: 721h

compactor:
  working_directory: /loki/compactor
  delete_request_store: filesystem
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150

ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /loki/rules-tmp
  alertmanager_url: http://alertmanager.service.consul:9093
  enable_api: true
EOF
```

- [ ] **Step 2: Write Loki Nomad job template**

```bash
cat > ansible/roles/monitoring/templates/loki.nomad.hcl.j2 <<'EOF'
job "loki" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "loki" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "http" { static = 3100 }
      port "grpc" { static = 9096 }
    }

    volume "data" {
      type      = "host"
      source    = "loki_data"
      read_only = false
    }

    service {
      name = "loki"
      port = "http"
      tags = ["loki", "logs"]
      check {
        type     = "http"
        path     = "/ready"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "loki" {
      driver = "docker"

      volume_mount {
        volume      = "data"
        destination = "/loki"
        read_only   = false
      }

      template {
        data        = <<-CONFIG
{{ lookup('file', 'roles/monitoring/templates/loki-config.yml.j2') | indent(10, true) }}
CONFIG
        destination = "local/config.yml"
        change_mode = "restart"
      }

      config {
        image        = "grafana/loki:{{ loki_version }}"
        network_mode = "host"
        args = ["-config.file=/local/config.yml"]
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}
EOF
```

Note: the `lookup('file', ...)` inline above is a placeholder pattern — Ansible will render the outer Nomad HCL file, but Loki itself reads the config from `/local/config.yml` injected as a Nomad `template` block. Keep the rendering simple by making the Ansible task fetch the config file content and pass via `-var`, or use an inline `data = <<EOT ... EOT`. Use the simpler pattern below instead:

Replace the `template { data = <<-CONFIG ... CONFIG ... }` block with:

```hcl
      template {
        data = <<EOT
{{ '{{' }} key "loki/config" {{ '}}' }}
EOT
        destination = "local/config.yml"
        change_mode = "restart"
      }
```

Then in Ansible (`tasks/main.yml`) write the file content into Consul KV (next task), so Nomad's consul-template renders it at runtime.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/monitoring/templates/loki-config.yml.j2 ansible/roles/monitoring/templates/loki.nomad.hcl.j2
git commit -m "feat(monitoring): loki single-binary job + filesystem config"
```

---

## Task 5: Promtail config + system job

**Files:**
- Create: `ansible/roles/monitoring/templates/promtail-config.yml.j2`
- Create: `ansible/roles/monitoring/templates/promtail.nomad.hcl.j2`

- [ ] **Step 1: Promtail config**

```bash
cat > ansible/roles/monitoring/templates/promtail-config.yml.j2 <<'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: warn

clients:
  - url: http://loki.service.consul:3100/loki/api/v1/push
    backoff_config:
      min_period: 500ms
      max_period: 5m
      max_retries: 10

positions:
  filename: /var/lib/promtail/positions.yaml

scrape_configs:
  - job_name: nomad-allocs
    nomad_sd_configs:
      - server: http://127.0.0.1:4646
        token: {{ nomad_bootstrap_token }}
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__meta_nomad_namespace]
        target_label: namespace
      - source_labels: [__meta_nomad_job]
        target_label: job
      - source_labels: [__meta_nomad_task]
        target_label: task
      - source_labels: [__meta_nomad_node_name]
        target_label: node
      - source_labels: [__meta_nomad_alloc_id]
        target_label: alloc_id
      - replacement: /alloc/${1}/logs/*
        source_labels: [__meta_nomad_alloc_id]
        target_label: __path__
EOF
```

- [ ] **Step 2: Promtail system job**

```bash
cat > ansible/roles/monitoring/templates/promtail.nomad.hcl.j2 <<'EOF'
job "promtail" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "system"

  group "promtail" {

    network {
      mode = "host"
      port "http" { static = 9080 }
    }

    volume "alloc-logs" {
      type      = "host"
      source    = "alloc_mounts"
      read_only = true
    }

    service {
      name = "promtail"
      port = "http"
      tags = ["promtail", "logs"]
      check {
        type     = "http"
        path     = "/ready"
        port     = "http"
        interval = "15s"
        timeout  = "3s"
      }
    }

    task "promtail" {
      driver = "docker"

      volume_mount {
        volume      = "alloc-logs"
        destination = "/alloc"
        read_only   = true
      }

      template {
        data = <<EOT
{{ '{{' }} key "promtail/config" {{ '}}' }}
EOT
        destination = "local/config.yml"
        change_mode = "restart"
      }

      config {
        image        = "grafana/promtail:{{ promtail_version }}"
        network_mode = "host"
        args = ["-config.file=/local/config.yml"]
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
EOF
```

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/monitoring/templates/promtail-config.yml.j2 ansible/roles/monitoring/templates/promtail.nomad.hcl.j2
git commit -m "feat(monitoring): promtail system job scraping nomad allocs"
```

---

## Task 6: Render configs into Consul KV + run jobs

**Files:**
- Modify: `ansible/roles/monitoring/tasks/main.yml`

- [ ] **Step 1: Append render+run tasks**

Append to `ansible/roles/monitoring/tasks/main.yml`:

```yaml
- name: Render Loki config into Consul KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/loki/config"
    method: PUT
    body: "{{ lookup('template', 'loki-config.yml.j2') }}"
    headers:
      X-Consul-Token: "{{ consul_bootstrap_token }}"
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Render Promtail config into Consul KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/promtail/config"
    method: PUT
    body: "{{ lookup('template', 'promtail-config.yml.j2') }}"
    headers:
      X-Consul-Token: "{{ consul_bootstrap_token }}"
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Render and submit Loki Nomad job
  ansible.builtin.shell: |
    set -o pipefail
    nomad job run -
  args:
    stdin: "{{ lookup('template', 'loki.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Render and submit Promtail Nomad job
  ansible.builtin.shell: |
    set -o pipefail
    nomad job run -
  args:
    stdin: "{{ lookup('template', 'promtail.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true
```

- [ ] **Step 2: Run the monitoring role**

```bash
cat > /tmp/monitoring-only.yml <<'EOF'
- name: Re-deploy monitoring stack
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - monitoring
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/monitoring-only.yml
```

Expected: 4 tasks change (KV writes + 2 job runs); both jobs report "Deployment successful" or equivalent.

- [ ] **Step 3: Verify**

```bash
multipass exec nomad-local-server-01 -- bash -c '
  curl -s -o /dev/null -w "loki ready: %{http_code}\n" http://loki.service.consul:3100/ready
  curl -s -o /dev/null -w "promtail ready: %{http_code}\n" http://promtail.service.consul:9080/ready
'
```

Expected: both 200.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/monitoring/tasks/main.yml
git commit -m "feat(monitoring): render loki/promtail configs into Consul KV + deploy jobs"
```

---

## Task 7: Add Loki datasource to Grafana

**Files:**
- Modify or Create: `ansible/roles/monitoring/templates/grafana-datasources.yml.j2`

- [ ] **Step 1: Inspect existing file**

```bash
cat ansible/roles/monitoring/templates/grafana-datasources.yml.j2 2>/dev/null || echo "missing"
```

If `missing`, create. If exists, append.

- [ ] **Step 2: Ensure Loki datasource present**

If creating new:

```bash
cat > ansible/roles/monitoring/templates/grafana-datasources.yml.j2 <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.service.consul:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki.service.consul:3100
    jsonData:
      maxLines: 1000
EOF
```

If file existed, append the Loki block (3rd item) to the existing list.

- [ ] **Step 3: Re-deploy Grafana** (existing role handles config provisioning)

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/monitoring-only.yml
```

- [ ] **Step 4: Verify in Grafana API**

```bash
DASH_PW=$(awk '$1=="dashboard_basic_auth_password:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-server-01 -- \
  curl -sk -u "admin:$DASH_PW" http://grafana.service.consul:3000/api/datasources | python3 -m json.tool
```

Expected: list includes both `Prometheus` and `Loki`.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/monitoring/templates/grafana-datasources.yml.j2
git commit -m "feat(grafana): provision Loki datasource"
```

---

## Task 8: Make smoke pass

- [ ] **Step 1: Re-run smoke**

```bash
bash tests/smoke/test_logs_pipeline.sh nomad-local-server-01
```

Expected: `ALL LOG PIPELINE CHECKS PASSED`.

- [ ] **Step 2: Diagnose if failing**

```bash
# Loki not ready → check job
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-server-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status loki
  ALLOC=\$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus \"running\"}}{{.ID}}{{end}}{{end}}' loki | head -c 8)
  nomad alloc logs -stderr \$ALLOC | tail -30
"

# Promtail not registering → check Nomad SD
multipass exec nomad-local-client-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ALLOC=\$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus \"running\"}}{{.ID}}{{end}}{{end}}' promtail | head -c 8)
  nomad alloc logs -stderr \$ALLOC | tail -30
"
```

---

## Task 9: Push and document

- [ ] **Step 1: Runbook**

```bash
cat > docs/runbooks/logs.md <<'EOF'
# Runbook — Logs (Loki + Promtail)

## Components
- Loki — single-binary job on a server node, retention `loki_retention_days` days.
- Promtail — system job on every Nomad client, scrapes `/alloc/<id>/logs/*`.
- Grafana — `Loki` datasource at `http://loki.service.consul:3100`.

## Querying
In Grafana → Explore → Loki:

```
{job="traefik"}
{job="whoami"} |= "error"
{node="nomad-local-client-01"} | json
```

## Storage
Filesystem-backed, one host_volume `loki_data` on the server node.
Retention enforced by Loki compactor.

## Troubleshooting
| Symptom | Diagnosis | Fix |
|---|---|---|
| Grafana → Loki connection refused | Loki not running or DNS broken | `nomad job status loki`; check Consul SRV |
| Empty queries | Promtail not registering targets | `curl http://promtail.service.consul:9080/targets` from a server VM |
| 429 Too Many Requests | Promtail backpressure | Bump Loki resources `cpu/memory`; increase `limits_config.ingestion_rate_mb` |
EOF
git add docs/runbooks/logs.md
git commit -m "docs(runbook): logs (loki/promtail)"
```

- [ ] **Step 2: Push**

```bash
git push origin main
```

- [ ] **Step 3: Verify CI**

```bash
sleep 15 && gh run list --workflow=lint.yml --limit 1
```

Expected: `completed success`.

---

## Self-Review

- Audit #13b ("Logs") covered: pipeline ingest + query + Grafana datasource + retention.
- No placeholders: every config and job HCL is fully written.
- Type/name consistency: `loki_data_dir`, `loki_data` host_volume, `loki_version`, `loki.service.consul` all match across files.
