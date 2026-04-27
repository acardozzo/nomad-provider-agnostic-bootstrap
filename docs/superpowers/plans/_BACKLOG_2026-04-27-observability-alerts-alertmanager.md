# Observability — Alerts (Alertmanager + Baseline Rules) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Alertmanager as a Nomad service job, wire Prometheus to it, ship a baseline rule set covering node/cluster health, and route alerts to a Slack webhook (configurable; defaults to a no-op receiver in local mode).

**Architecture:** Alertmanager (`prom/alertmanager:0.27`) runs as a single Nomad service constrained to a server node, persisting silences/notifications to a host_volume. Prometheus is reconfigured with `alerting.alertmanagers` and `rule_files`. A separate Ansible task ships rule YAMLs for: node down, disk pressure, memory pressure, Nomad allocation churn, Traefik 5xx rate, Consul leader loss.

**Tech Stack:** Alertmanager 0.27.x, Prometheus (existing role), Nomad service job, Consul SD, optional Slack webhook.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/monitoring/templates/alertmanager.nomad.hcl.j2` | AM service job |
| `ansible/roles/monitoring/templates/alertmanager-config.yml.j2` | AM routing/receivers config |
| `ansible/roles/monitoring/templates/prometheus-rules-baseline.yml.j2` | 6 baseline alert rules |
| `ansible/roles/monitoring/templates/prometheus.yml.j2` (modify existing) | Add `alerting:` and `rule_files:` blocks |
| `ansible/roles/monitoring/tasks/main.yml` | Render configs into Consul KV + run AM job |
| `ansible/roles/nomad/tasks/main.yml` | Pre-create `/opt/alertmanager` directory |
| `ansible/roles/nomad/templates/nomad-client.hcl.j2` | Add `host_volume "alertmanager_data"` |
| `ansible/inventory/group_vars/all/defaults.yml` | Add `alertmanager_version`, `alert_slack_webhook_url` (optional) |
| `tests/smoke/test_alerts_pipeline.sh` | Verify AM up, Prometheus has rules loaded, force-fire a synthetic alert |

---

## Task 1: Defaults

- [ ] **Step 1: Append to defaults.yml**

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Alerting
alertmanager_version: "0.27.0"
alertmanager_data_dir: "/opt/alertmanager"
# Set to a real Slack incoming webhook URL to enable Slack alerts.
# Leave empty to use the local-mode no-op receiver.
alert_slack_webhook_url: ""
alert_default_receiver: "{{ 'slack' if alert_slack_webhook_url else 'devnull' }}"
EOF
```

- [ ] **Step 2: Commit**

```bash
git add ansible/inventory/group_vars/all/defaults.yml
git commit -m "chore(monitoring): alertmanager + slack webhook defaults"
```

---

## Task 2: Failing smoke

- [ ] **Step 1: Write smoke**

```bash
cat > tests/smoke/test_alerts_pipeline.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"

echo "=== Alertmanager ready ==="
code=$(multipass exec "$VM" -- bash -c "
  curl -s -o /dev/null -w '%{http_code}' http://alertmanager.service.consul:9093/-/ready || true
")
[[ "$code" == "200" ]] && echo "OK" || { echo "FAIL: $code"; exit 1; }

echo "=== Prometheus has rules loaded ==="
rules=$(multipass exec "$VM" -- bash -c "
  curl -s 'http://prometheus.service.consul:9090/api/v1/rules' || true
")
if ! echo "$rules" | grep -q 'NodeDown\|HighDiskUsage'; then
  echo "FAIL: baseline rules missing, body=$rules" >&2
  exit 1
fi
echo "OK"

echo "=== Synthetic alert fires end-to-end ==="
multipass exec "$VM" -- bash -c '
  curl -s -X POST http://alertmanager.service.consul:9093/api/v2/alerts \
    -H "Content-Type: application/json" \
    -d "[{\"labels\":{\"alertname\":\"SmokeTest\",\"severity\":\"warning\"},\"annotations\":{\"summary\":\"smoke test\"},\"startsAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]"
'
sleep 3
active=$(multipass exec "$VM" -- bash -c "
  curl -s 'http://alertmanager.service.consul:9093/api/v2/alerts?active=true&filter=alertname=SmokeTest'
")
if ! echo "$active" | grep -q SmokeTest; then
  echo "FAIL: synthetic alert not active in AM, body=$active" >&2
  exit 1
fi
echo "OK"

echo "ALL ALERT PIPELINE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_alerts_pipeline.sh
```

- [ ] **Step 2: Run, expect failure**

```bash
bash tests/smoke/test_alerts_pipeline.sh nomad-local-server-01
```

Expected: FAIL on AM ready.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke/test_alerts_pipeline.sh
git commit -m "test(alerts): failing smoke for alertmanager pipeline"
```

---

## Task 3: AM host_volume + dir

**Files:**
- Modify: `ansible/roles/nomad/tasks/main.yml`
- Modify: `ansible/roles/nomad/templates/nomad-client.hcl.j2`

- [ ] **Step 1: Pre-create dir**

In `ansible/roles/nomad/tasks/main.yml` near the existing dir loop, append:

```yaml
- name: Ensure Alertmanager data dir
  ansible.builtin.file:
    path: "{{ alertmanager_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
```

- [ ] **Step 2: host_volume in nomad-client.hcl.j2**

Add inside `client { ... }` block near other `host_volume` declarations:

```hcl
  host_volume "alertmanager_data" {
    path      = "{{ alertmanager_data_dir }}"
    read_only = false
  }
```

- [ ] **Step 3: Re-render Nomad**

```bash
cat > /tmp/nomad-only.yml <<'EOF'
- name: Re-render
  hosts: all
  become: true
  roles:
    - nomad
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/nomad-only.yml
```

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/nomad/tasks/main.yml ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(nomad): alertmanager_data host_volume + dir"
```

---

## Task 4: AM config + job

**Files:**
- Create: `ansible/roles/monitoring/templates/alertmanager-config.yml.j2`
- Create: `ansible/roles/monitoring/templates/alertmanager.nomad.hcl.j2`

- [ ] **Step 1: AM config**

```bash
cat > ansible/roles/monitoring/templates/alertmanager-config.yml.j2 <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: "{{ alert_default_receiver }}"
  group_by: ["alertname", "cluster", "service"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers:
        - severity = critical
      receiver: "{{ alert_default_receiver }}"
      group_wait: 0s
      repeat_interval: 1h

receivers:
  - name: devnull
  - name: slack
{% if alert_slack_webhook_url %}
    slack_configs:
      - api_url: "{{ alert_slack_webhook_url }}"
        channel: "#alerts"
        send_resolved: true
        title: "[{% raw %}{{ .Status | toUpper }}{% endraw %}] {% raw %}{{ .CommonLabels.alertname }}{% endraw %}"
        text: |
          {% raw %}{{ range .Alerts }}*{{ .Labels.severity }}* {{ .Annotations.summary }}
          {{ .Annotations.description }}
          {{ end }}{% endraw %}
{% endif %}

inhibit_rules:
  - source_matchers:
      - severity = critical
    target_matchers:
      - severity = warning
    equal: ["alertname", "instance"]
EOF
```

- [ ] **Step 2: AM job**

```bash
cat > ansible/roles/monitoring/templates/alertmanager.nomad.hcl.j2 <<'EOF'
job "alertmanager" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "alertmanager" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "http"     { static = 9093 }
      port "cluster"  { static = 9094 }
    }

    volume "data" {
      type      = "host"
      source    = "alertmanager_data"
      read_only = false
    }

    service {
      name = "alertmanager"
      port = "http"
      tags = ["alerts"]
      check {
        type     = "http"
        path     = "/-/ready"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "alertmanager" {
      driver = "docker"

      volume_mount {
        volume      = "data"
        destination = "/alertmanager"
        read_only   = false
      }

      template {
        data = <<EOT
{{ '{{' }} key "alertmanager/config" {{ '}}' }}
EOT
        destination = "local/config.yml"
        change_mode = "restart"
      }

      config {
        image        = "prom/alertmanager:v{{ alertmanager_version }}"
        network_mode = "host"
        args = [
          "--config.file=/local/config.yml",
          "--storage.path=/alertmanager",
          "--web.listen-address=:9093",
          "--cluster.listen-address=:9094",
        ]
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
git add ansible/roles/monitoring/templates/alertmanager-config.yml.j2 ansible/roles/monitoring/templates/alertmanager.nomad.hcl.j2
git commit -m "feat(monitoring): alertmanager job + slack/devnull receivers"
```

---

## Task 5: Baseline alert rules

**Files:**
- Create: `ansible/roles/monitoring/templates/prometheus-rules-baseline.yml.j2`

- [ ] **Step 1: Write rules**

```bash
cat > ansible/roles/monitoring/templates/prometheus-rules-baseline.yml.j2 <<'EOF'
groups:
  - name: cluster-health
    interval: 30s
    rules:
      - alert: NodeDown
        expr: up{job="node-exporter"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Node {% raw %}{{ $labels.instance }}{% endraw %} is down"
          description: "Node-exporter has not responded for 2m."

      - alert: HighDiskUsage
        expr: 100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) > 85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Disk >85% on {% raw %}{{ $labels.instance }}{% endraw %}"
          description: "Root filesystem usage is {% raw %}{{ $value | printf \"%.1f\" }}%{% endraw %}."

      - alert: HighMemoryUsage
        expr: 100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Memory >90% on {% raw %}{{ $labels.instance }}{% endraw %}"
          description: "Available memory is critically low."

      - alert: NomadAllocChurn
        expr: rate(nomad_nomad_evaluations_total[10m]) > 5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Nomad allocation churn elevated"
          description: "Eval rate is {% raw %}{{ $value }}{% endraw %} per second over 10m."

      - alert: TraefikHigh5xx
        expr: |
          sum(rate(traefik_service_requests_total{code=~"5.."}[5m]))
          /
          sum(rate(traefik_service_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Traefik serving >5% 5xx"
          description: "5xx ratio is {% raw %}{{ $value | printf \"%.2f\" }}{% endraw %} over 5m."

      - alert: ConsulLeaderLoss
        expr: consul_raft_leader == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Consul has no leader"
          description: "Consul cluster lost its Raft leader."
EOF
```

- [ ] **Step 2: Commit**

```bash
git add ansible/roles/monitoring/templates/prometheus-rules-baseline.yml.j2
git commit -m "feat(monitoring): baseline alert rules (6 alerts)"
```

---

## Task 6: Wire Prometheus to AM + load rules

**Files:**
- Modify: `ansible/roles/monitoring/templates/prometheus.yml.j2` (or whatever the existing prometheus config template is)

- [ ] **Step 1: Find existing prometheus config template**

```bash
ls ansible/roles/monitoring/templates/ | grep -i prom
```

Identify the file (likely `prometheus.yml.j2`).

- [ ] **Step 2: Add `alerting:` and `rule_files:` blocks**

Open the file and append at the top level (NOT inside `scrape_configs:`):

```yaml

alerting:
  alertmanagers:
    - consul_sd_configs:
        - server: "127.0.0.1:8500"
          token: "{{ consul_bootstrap_token }}"
          services: ["alertmanager"]

rule_files:
  - /etc/prometheus/rules/*.yml
```

If `prometheus.yml.j2` injects scrape config inline, ensure these new blocks are siblings of `scrape_configs:` not nested.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/monitoring/templates/prometheus.yml.j2
git commit -m "feat(prometheus): point at alertmanager + load rule files"
```

---

## Task 7: Render configs + run job + reload Prometheus

**Files:**
- Modify: `ansible/roles/monitoring/tasks/main.yml`

- [ ] **Step 1: Append render+run**

Append:

```yaml
- name: Render Alertmanager config to Consul KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/alertmanager/config"
    method: PUT
    body: "{{ lookup('template', 'alertmanager-config.yml.j2') }}"
    headers:
      X-Consul-Token: "{{ consul_bootstrap_token }}"
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Render baseline rules to Consul KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/prometheus/rules/baseline.yml"
    method: PUT
    body: "{{ lookup('template', 'prometheus-rules-baseline.yml.j2') }}"
    headers:
      X-Consul-Token: "{{ consul_bootstrap_token }}"
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Submit Alertmanager job
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'alertmanager.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Trigger Prometheus reload
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:9090/-/reload"
    method: POST
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false
```

The Prometheus job template likely already mounts `/etc/prometheus/rules/`. Confirm by reading the existing prometheus.nomad.hcl.j2 and add a Consul-template block that watches `prometheus/rules/*` and writes into `/local/rules/`. If absent, add to the prometheus task config:

```hcl
      template {
        data = <<EOT
{{ '{{' }} key "prometheus/rules/baseline.yml" {{ '}}' }}
EOT
        destination = "local/rules/baseline.yml"
        change_mode = "signal"
        change_signal = "SIGHUP"
      }
```

And update prometheus's args to add `--web.enable-lifecycle` if missing.

- [ ] **Step 2: Run monitoring role**

```bash
cat > /tmp/monitoring-only.yml <<'EOF'
- name: Re-deploy monitoring
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

- [ ] **Step 3: Verify**

```bash
multipass exec nomad-local-server-01 -- bash -c '
  curl -s -o /dev/null -w "AM: %{http_code}\n" http://alertmanager.service.consul:9093/-/ready
  curl -s http://prometheus.service.consul:9090/api/v1/rules | python3 -c "import sys,json; d=json.load(sys.stdin); print(\"groups:\", len(d[\"data\"][\"groups\"]))"
'
```

Expected: `AM: 200`; `groups: 1` (or more).

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/monitoring/tasks/main.yml ansible/roles/monitoring/templates/prometheus.nomad.hcl.j2
git commit -m "feat(monitoring): deploy alertmanager + load rules into prometheus"
```

---

## Task 8: Make smoke pass

```bash
bash tests/smoke/test_alerts_pipeline.sh nomad-local-server-01
```

Expected: `ALL ALERT PIPELINE CHECKS PASSED`.

If the synthetic alert assertion fails, check AM logs:

```bash
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-server-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ALLOC=\$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus \"running\"}}{{.ID}}{{end}}{{end}}' alertmanager | head -c 8)
  nomad alloc logs -stderr \$ALLOC | tail -30
"
```

---

## Task 9: Push + runbook

```bash
cat > docs/runbooks/alerts.md <<'EOF'
# Runbook — Alerts (Alertmanager)

## Components
- Alertmanager — single instance on a server node, port 9093.
- Prometheus — loads rules from Consul KV via consul-template, reloads on SIGHUP.
- 6 baseline rules: NodeDown, HighDiskUsage, HighMemoryUsage, NomadAllocChurn,
  TraefikHigh5xx, ConsulLeaderLoss.

## Routing
- Default receiver: `slack` if `alert_slack_webhook_url` set, else `devnull`.
- Critical alerts: 1h repeat interval, no group_wait.
- Warning alerts: 4h repeat interval, 30s group_wait.

## Adding a new rule
1. Append to `ansible/roles/monitoring/templates/prometheus-rules-baseline.yml.j2`
   (or create a new `<topic>-rules.yml.j2`).
2. Add an Ansible task that uploads it to Consul KV under
   `prometheus/rules/<filename>.yml`.
3. Add a corresponding `template` block in `prometheus.nomad.hcl.j2`.
4. Re-run the monitoring role.
5. Verify: `curl http://prometheus.service.consul:9090/api/v1/rules`.

## Silencing an alert
```bash
amtool silence add alertname=NodeDown instance=nomad-local-client-01 \
  --duration=2h --comment="planned reboot"
```

## Troubleshooting
| Symptom | Fix |
|---|---|
| Rules not loaded | Ensure `--web.enable-lifecycle` arg present, then POST `/-/reload` |
| Slack not firing | Verify `alert_slack_webhook_url` set; check AM `/api/v2/status` for receiver errors |
| Stuck alert | `amtool alert query` then `amtool silence add ...` |
EOF
git add docs/runbooks/alerts.md
git commit -m "docs(runbook): alerts pipeline"
git push origin main
```

---

## Self-Review

- Audit #13d ("Alerts") covered: AM, rule loading, default routing, silencing path, 6 baseline rules.
- No placeholders: all 6 rules have concrete PromQL.
- Type/name consistency: `alertmanager_data_dir`, `alertmanager_data` volume, `alertmanager_version` aligned.
