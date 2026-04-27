# Observability — Traces (Tempo + OpenTelemetry Collector) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Tempo + OpenTelemetry Collector as Nomad jobs so apps can emit traces (OTLP/gRPC and OTLP/HTTP), traces are stored in Tempo, and Grafana exposes a Tempo datasource alongside Prometheus + Loki.

**Architecture:** OTel Collector runs as a Nomad system job on every client; receives OTLP on `:4317` (gRPC) / `:4318` (HTTP); exports to Tempo. Tempo runs as a single Nomad service job on a server, persisting blocks to a `tempo_data` host_volume. Grafana auto-provisions the Tempo datasource.

**Tech Stack:** Tempo 2.6.x, OpenTelemetry Collector contrib 0.110+, existing Grafana role, Consul SD.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/monitoring/templates/tempo-config.yml.j2` | Tempo single-binary config |
| `ansible/roles/monitoring/templates/tempo.nomad.hcl.j2` | Tempo service job |
| `ansible/roles/monitoring/templates/otelcol-config.yml.j2` | OTel Collector config |
| `ansible/roles/monitoring/templates/otelcol.nomad.hcl.j2` | OTel system job |
| `ansible/roles/monitoring/templates/grafana-datasources.yml.j2` | Append Tempo datasource |
| `ansible/roles/monitoring/tasks/main.yml` | Render configs to Consul KV + run jobs |
| `ansible/roles/nomad/templates/nomad-client.hcl.j2` | Add `tempo_data` host_volume |
| `ansible/inventory/group_vars/all/defaults.yml` | Versions + retention |
| `tests/smoke/test_traces_pipeline.sh` | Push synthetic trace via OTel HTTP, query Tempo, assert |

---

## Task 1: Defaults + failing smoke

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Traces
tempo_version: "2.6.1"
otelcol_version: "0.110.0"
tempo_data_dir: "/opt/tempo"
tempo_retention_days: 14
EOF

cat > tests/smoke/test_traces_pipeline.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"

echo "=== Tempo ready ==="
code=$(multipass exec "$VM" -- curl -s -o /dev/null -w '%{http_code}' http://tempo.service.consul:3200/ready || true)
[[ "$code" == "200" ]] || { echo "FAIL tempo $code"; exit 1; }
echo OK

echo "=== OTel collector listening ==="
code=$(multipass exec "$VM" -- curl -s -o /dev/null -w '%{http_code}' http://otelcol.service.consul:13133/ || true)
[[ "$code" == "200" ]] || { echo "FAIL otelcol $code"; exit 1; }
echo OK

echo "=== push synthetic span via OTLP HTTP ==="
TS_NS=$(($(date +%s)*1000000000))
TID=$(openssl rand -hex 16)
SID=$(openssl rand -hex 8)
multipass exec "$VM" -- bash -c "
curl -sS -X POST http://otelcol.service.consul:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"smoke\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TID\",\"spanId\":\"$SID\",\"name\":\"test\",\"kind\":1,\"startTimeUnixNano\":\"$TS_NS\",\"endTimeUnixNano\":\"$(($TS_NS+1000000))\"}]}]}]}'
"
sleep 5

echo "=== Tempo serves the span ==="
got=$(multipass exec "$VM" -- bash -c "curl -s http://tempo.service.consul:3200/api/traces/$TID")
echo "$got" | grep -q '"name":"test"' || { echo "FAIL: span not in tempo: $got"; exit 1; }
echo "OK"

echo "ALL TRACE PIPELINE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_traces_pipeline.sh

git add ansible/inventory/group_vars/all/defaults.yml tests/smoke/test_traces_pipeline.sh
git commit -m "test(traces): defaults + failing smoke for tempo/otelcol"
```

Expected on first run: FAIL on `tempo $code`.

---

## Task 2: Tempo config + job

```bash
cat > ansible/roles/monitoring/templates/tempo-config.yml.j2 <<'EOF'
server:
  http_listen_port: 3200
  log_level: warn

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4319
        http:
          endpoint: 0.0.0.0:4320

ingester:
  trace_idle_period: 10s
  max_block_duration: 5m

compactor:
  compaction:
    block_retention: {{ tempo_retention_days * 24 }}h

storage:
  trace:
    backend: local
    local:
      path: /tempo/traces
    wal:
      path: /tempo/wal

usage_report:
  reporting_enabled: false
EOF

cat > ansible/roles/monitoring/templates/tempo.nomad.hcl.j2 <<'EOF'
job "tempo" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "tempo" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "http"      { static = 3200 }
      port "otlp_grpc" { static = 4319 }
      port "otlp_http" { static = 4320 }
    }

    volume "data" {
      type      = "host"
      source    = "tempo_data"
      read_only = false
    }

    service {
      name = "tempo"
      port = "http"
      check {
        type     = "http"
        path     = "/ready"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "tempo" {
      driver = "docker"

      volume_mount {
        volume      = "data"
        destination = "/tempo"
        read_only   = false
      }

      template {
        data = <<EOT
{{ '{{' }} key "tempo/config" {{ '}}' }}
EOT
        destination = "local/config.yml"
        change_mode = "restart"
      }

      config {
        image        = "grafana/tempo:{{ tempo_version }}"
        network_mode = "host"
        args = ["-config.file=/local/config.yml"]
      }

      resources { cpu = 300; memory = 512 }
    }
  }
}
EOF

git add ansible/roles/monitoring/templates/tempo-config.yml.j2 ansible/roles/monitoring/templates/tempo.nomad.hcl.j2
git commit -m "feat(monitoring): tempo single-binary job"
```

---

## Task 3: OTel Collector

```bash
cat > ansible/roles/monitoring/templates/otelcol-config.yml.j2 <<'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024

exporters:
  otlp/tempo:
    endpoint: tempo.service.consul:4319
    tls:
      insecure: true

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo]
  telemetry:
    logs:
      level: warn
EOF

cat > ansible/roles/monitoring/templates/otelcol.nomad.hcl.j2 <<'EOF'
job "otelcol" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "system"

  group "otelcol" {
    network {
      mode = "host"
      port "otlp_grpc" { static = 4317 }
      port "otlp_http" { static = 4318 }
      port "health"    { static = 13133 }
    }

    service {
      name = "otelcol"
      port = "health"
      check {
        type     = "http"
        path     = "/"
        port     = "health"
        interval = "15s"
        timeout  = "3s"
      }
    }

    task "otelcol" {
      driver = "docker"

      template {
        data = <<EOT
{{ '{{' }} key "otelcol/config" {{ '}}' }}
EOT
        destination = "local/config.yml"
        change_mode = "restart"
      }

      config {
        image        = "otel/opentelemetry-collector-contrib:{{ otelcol_version }}"
        network_mode = "host"
        args = ["--config=/local/config.yml"]
      }

      resources { cpu = 100; memory = 128 }
    }
  }
}
EOF

git add ansible/roles/monitoring/templates/otelcol-config.yml.j2 ansible/roles/monitoring/templates/otelcol.nomad.hcl.j2
git commit -m "feat(monitoring): otelcol system job"
```

---

## Task 4: host_volume + render+run

In `nomad-client.hcl.j2`:

```hcl
  host_volume "tempo_data" {
    path      = "{{ tempo_data_dir }}"
    read_only = false
  }
```

Append to `monitoring/tasks/main.yml`:

```yaml
- name: Ensure tempo data dir
  ansible.builtin.file:
    path: "{{ tempo_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Render tempo config to KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/tempo/config"
    method: PUT
    body: "{{ lookup('template', 'tempo-config.yml.j2') }}"
    headers: { X-Consul-Token: "{{ consul_bootstrap_token }}" }
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Render otelcol config to KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/otelcol/config"
    method: PUT
    body: "{{ lookup('template', 'otelcol-config.yml.j2') }}"
    headers: { X-Consul-Token: "{{ consul_bootstrap_token }}" }
    status_code: 200
  run_once: true
  delegate_to: localhost
  become: false

- name: Submit tempo job
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'tempo.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true

- name: Submit otelcol job
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'otelcol.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  run_once: true
  delegate_to: localhost
  become: false
  changed_when: true
```

Run:

```bash
cat > /tmp/monitoring-only.yml <<'EOF'
- hosts: localhost
  connection: local
  gather_facts: false
  roles: [monitoring]
EOF
cat > /tmp/nomad-only.yml <<'EOF'
- hosts: all
  become: true
  roles: [nomad]
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/nomad-only.yml /tmp/monitoring-only.yml
```

Commit:

```bash
git add ansible/roles/monitoring/tasks/main.yml ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(monitoring): render+submit tempo+otelcol; add host_volume"
```

---

## Task 5: Grafana datasource

In `grafana-datasources.yml.j2` append:

```yaml
  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo.service.consul:3200
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
```

Run monitoring role again. Verify:

```bash
DASH_PW=$(awk '$1=="dashboard_basic_auth_password:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-server-01 -- \
  curl -sk -u "admin:$DASH_PW" http://grafana.service.consul:3000/api/datasources | python3 -m json.tool | grep -E 'name|type'
```

Expected: contains `Prometheus`, `Loki`, `Tempo`.

Commit:

```bash
git add ansible/roles/monitoring/templates/grafana-datasources.yml.j2
git commit -m "feat(grafana): provision tempo datasource"
```

---

## Task 6: Smoke + push + runbook

```bash
bash tests/smoke/test_traces_pipeline.sh nomad-local-server-01
```

Expected: passes.

Runbook:

```bash
cat > docs/runbooks/traces.md <<'EOF'
# Runbook — Traces (Tempo + OTel Collector)

## Endpoints
- OTLP/gRPC: `otelcol.service.consul:4317` or `<client-ip>:4317`
- OTLP/HTTP: `otelcol.service.consul:4318` or `<client-ip>:4318`
- Tempo HTTP API: `tempo.service.consul:3200`

## Apps emit traces
Set in app env:
```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol.service.consul:4318
OTEL_SERVICE_NAME=<app-name>
```

## Querying in Grafana
Explore → Tempo → Trace ID search. From Loki, "Logs to Trace" links by `trace_id` log field if present.

## Storage
Local filesystem under `/opt/tempo`. Retention `tempo_retention_days`.
For multi-region, swap `storage.trace.backend` to `s3` or `gcs`.
EOF
git add docs/runbooks/traces.md
git commit -m "docs(runbook): traces"
git push origin main
```

---

## Self-Review

- Audit #13c covered: OTLP ingest + Tempo storage + Grafana datasource + retention.
- No placeholders.
- Type/name consistency: `tempo_*`, `otelcol_*`, ports 3200/4317/4318/4319/4320 distinct.
