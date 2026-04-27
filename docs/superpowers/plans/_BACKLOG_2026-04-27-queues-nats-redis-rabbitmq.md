# Queues / Streaming (NATS, Redis, RabbitMQ) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide three message-queue/streaming primitives as Nomad jobs apps can adopt: NATS (lightweight pub/sub), Redis (cache + pub/sub + streams), RabbitMQ (AMQP). Each as a separate Ansible role with sensible defaults and Consul service discovery. Closes audit #10.

**Architecture:** Each queue runs as a 1-node Nomad service job (HA later via clustering). Persistence via host_volumes. Apps consume via `<svc>.service.consul`. Auth: NATS via JWT/operator account, Redis via password, RabbitMQ via user/password.

**Tech Stack:** NATS 2.10+, Redis 7.4+, RabbitMQ 3.13+ with management plugin.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/nats/templates/{config.conf,job.nomad.hcl}.j2` | NATS server |
| `ansible/roles/redis/templates/{redis.conf,job.nomad.hcl}.j2` | Redis |
| `ansible/roles/rabbitmq/templates/{advanced.config,job.nomad.hcl}.j2` | RabbitMQ |
| `ansible/roles/{nats,redis,rabbitmq}/tasks/main.yml` | Submit job |
| `ansible/inventory/group_vars/all/defaults.yml` | versions |
| `ansible/inventory/group_vars/all/secrets.example.yml` | passwords |
| `tests/smoke/test_queues.sh` | pub/sub roundtrip on each queue |

---

## Task 1: Defaults

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Queues
nats_version: "2.10.20"
redis_version: "7.4.1"
rabbitmq_version: "3.13.7-management"
nats_data_dir: "/opt/nats"
redis_data_dir: "/opt/redis"
rabbitmq_data_dir: "/opt/rabbitmq"
EOF
cat >> ansible/inventory/group_vars/all/secrets.example.yml <<'EOF'
redis_password: ""
rabbitmq_admin_user: "orbtyadmin"
rabbitmq_admin_password: ""
EOF

git add ansible/inventory/group_vars/all/defaults.yml ansible/inventory/group_vars/all/secrets.example.yml
git commit -m "chore(queues): defaults + secret schema"
```

---

## Task 2: Failing smoke

```bash
cat > tests/smoke/test_queues.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
SECRETS="$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml"
RPASS=$(awk '$1=="redis_password:" {print $2}' "$SECRETS" | tr -d \")
RABBIT_USER=$(awk '$1=="rabbitmq_admin_user:" {print $2}' "$SECRETS" | tr -d \")
RABBIT_PASS=$(awk '$1=="rabbitmq_admin_password:" {print $2}' "$SECRETS" | tr -d \")

echo "=== NATS publish/subscribe ==="
multipass exec "$VM" -- bash -c "
  command -v nats >/dev/null || curl -sLO https://github.com/nats-io/natscli/releases/latest/download/nats-0.1.5-linux-arm64.zip && unzip -o nats-*.zip && sudo mv nats-*/nats /usr/local/bin/
  nats --server nats://nats.service.consul:4222 sub smoke > /tmp/sub.out &
  SUBPID=\$!
  sleep 2
  nats --server nats://nats.service.consul:4222 pub smoke 'hello'
  sleep 2
  kill \$SUBPID || true
  grep -q hello /tmp/sub.out
" || { echo FAIL nats; exit 1; }
echo OK

echo "=== Redis SET/GET ==="
multipass exec "$VM" -- bash -c "
  apt-get install -y redis-tools 2>/dev/null || true
  redis-cli -h redis.service.consul -a '$RPASS' SET smokekey hello >/dev/null
  redis-cli -h redis.service.consul -a '$RPASS' GET smokekey
" | grep -q hello || { echo FAIL redis; exit 1; }
echo OK

echo "=== RabbitMQ HTTP API alive ==="
code=$(multipass exec "$VM" -- curl -s -o /dev/null -w '%{http_code}' -u "$RABBIT_USER:$RABBIT_PASS" http://rabbitmq.service.consul:15672/api/overview)
[[ "$code" == "200" ]] || { echo "FAIL rabbit $code"; exit 1; }
echo OK

echo "ALL QUEUE CHECKS PASSED"
EOF
chmod +x tests/smoke/test_queues.sh
git add tests/smoke/test_queues.sh
git commit -m "test(queues): failing smoke for nats/redis/rabbitmq"
```

---

## Task 3: NATS

```bash
mkdir -p ansible/roles/nats/{tasks,templates}
cat > ansible/roles/nats/templates/job.nomad.hcl.j2 <<'EOF'
job "nats" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "nats" {
    count = 1

    constraint { attribute = "${node.class}" operator = "=" value = "server" }

    network {
      mode = "host"
      port "client" { static = 4222 }
      port "monitor" { static = 8222 }
    }

    volume "data" { type = "host" source = "nats_data" read_only = false }

    service {
      name = "nats"
      port = "client"
      check { type = "tcp" port = "client" interval = "10s" timeout = "2s" }
    }

    task "nats" {
      driver = "docker"

      volume_mount { volume = "data" destination = "/data" read_only = false }

      config {
        image        = "nats:{{ nats_version }}"
        network_mode = "host"
        args = ["-js", "-sd", "/data", "-m", "8222"]
      }

      resources { cpu = 200 memory = 256 }
    }
  }
}
EOF
cat > ansible/roles/nats/tasks/main.yml <<'EOF'
---
- name: Ensure data dir
  ansible.builtin.file: { path: "{{ nats_data_dir }}", state: directory, mode: "0755" }
- name: Submit nats
  ansible.builtin.shell: nomad job run -
  args: { stdin: "{{ lookup('template', 'job.nomad.hcl.j2') }}", executable: /bin/bash }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF
git add ansible/roles/nats/
git commit -m "feat(nats): single-node nomad job + jetstream"
```

Add `host_volume "nats_data"` to nomad-client.hcl.j2.

---

## Task 4: Redis

```bash
mkdir -p ansible/roles/redis/{tasks,templates}
cat > ansible/roles/redis/templates/redis.conf.j2 <<'EOF'
bind 0.0.0.0
port 6379
requirepass {{ redis_password }}
appendonly yes
appendfsync everysec
dir /data
maxmemory 512mb
maxmemory-policy allkeys-lru
EOF
cat > ansible/roles/redis/templates/job.nomad.hcl.j2 <<'EOF'
job "redis" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "redis" {
    count = 1

    constraint { attribute = "${node.class}" operator = "=" value = "server" }

    network {
      mode = "host"
      port "redis" { static = 6379 }
    }

    volume "data" { type = "host" source = "redis_data" read_only = false }

    service {
      name = "redis"
      port = "redis"
      check { type = "tcp" port = "redis" interval = "10s" timeout = "2s" }
    }

    task "redis" {
      driver = "docker"

      volume_mount { volume = "data" destination = "/data" read_only = false }

      template {
        data = <<EOT
{{ '{{' }} key "redis/redis.conf" {{ '}}' }}
EOT
        destination = "local/redis.conf"
        change_mode = "restart"
      }

      config {
        image        = "redis:{{ redis_version }}"
        network_mode = "host"
        args = ["redis-server", "/local/redis.conf"]
      }

      resources { cpu = 200 memory = 512 }
    }
  }
}
EOF
cat > ansible/roles/redis/tasks/main.yml <<'EOF'
---
- name: Ensure data dir
  ansible.builtin.file: { path: "{{ redis_data_dir }}", state: directory, mode: "0755" }
- name: Render redis.conf to KV
  ansible.builtin.uri:
    url: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:8500/v1/kv/redis/redis.conf"
    method: PUT
    body: "{{ lookup('template', 'redis.conf.j2') }}"
    headers: { X-Consul-Token: "{{ consul_bootstrap_token }}" }
    status_code: 200
  delegate_to: localhost
  become: false
  run_once: true
- name: Submit redis
  ansible.builtin.shell: nomad job run -
  args: { stdin: "{{ lookup('template', 'job.nomad.hcl.j2') }}", executable: /bin/bash }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF
git add ansible/roles/redis/
git commit -m "feat(redis): single-node nomad job + AOF"
```

Add `host_volume "redis_data"` to nomad-client.hcl.j2.

---

## Task 5: RabbitMQ

```bash
mkdir -p ansible/roles/rabbitmq/{tasks,templates}
cat > ansible/roles/rabbitmq/templates/job.nomad.hcl.j2 <<'EOF'
job "rabbitmq" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"

  group "rabbitmq" {
    count = 1

    constraint { attribute = "${node.class}" operator = "=" value = "server" }

    network {
      mode = "host"
      port "amqp" { static = 5672 }
      port "mgmt" { static = 15672 }
    }

    volume "data" { type = "host" source = "rabbitmq_data" read_only = false }

    service {
      name = "rabbitmq"
      port = "amqp"
      check { type = "tcp" port = "amqp" interval = "10s" timeout = "2s" }
    }

    task "rabbitmq" {
      driver = "docker"

      env {
        RABBITMQ_DEFAULT_USER = "{{ rabbitmq_admin_user }}"
        RABBITMQ_DEFAULT_PASS = "{{ rabbitmq_admin_password }}"
      }

      volume_mount { volume = "data" destination = "/var/lib/rabbitmq" read_only = false }

      config {
        image        = "rabbitmq:{{ rabbitmq_version }}"
        network_mode = "host"
      }

      resources { cpu = 300 memory = 512 }
    }
  }
}
EOF
cat > ansible/roles/rabbitmq/tasks/main.yml <<'EOF'
---
- name: Ensure data dir
  ansible.builtin.file: { path: "{{ rabbitmq_data_dir }}", state: directory, mode: "0755" }
- name: Submit rabbitmq
  ansible.builtin.shell: nomad job run -
  args: { stdin: "{{ lookup('template', 'job.nomad.hcl.j2') }}", executable: /bin/bash }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF
git add ansible/roles/rabbitmq/
git commit -m "feat(rabbitmq): single-node nomad job + management plugin"
```

Add `host_volume "rabbitmq_data"` to nomad-client.hcl.j2.

---

## Task 6: Run + smoke + push

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags nats,redis,rabbitmq,nomad
bash tests/smoke/test_queues.sh nomad-local-server-01

cat > docs/runbooks/queues.md <<'EOF'
# Runbook — Queues

## Three primitives
- **NATS** — pub/sub + JetStream. Client URL: `nats://nats.service.consul:4222`.
- **Redis** — cache, pub/sub, streams. URL: `redis://:<pass>@redis.service.consul:6379`.
- **RabbitMQ** — AMQP, complex routing. URL: `amqp://<user>:<pass>@rabbitmq.service.consul:5672`. Mgmt UI at `:15672`.

## Choose which
| Need | Choice |
|---|---|
| Lightweight fan-out, low latency | NATS |
| Cache + simple pub/sub | Redis |
| Routing patterns, dead-letter, AMQP clients | RabbitMQ |

## HA upgrade path
Each is single-node here. To make HA:
- **NATS:** add 2 nodes, configure `cluster {}` block, JetStream R3 streams.
- **Redis:** Sentinel or Redis-Cluster.
- **RabbitMQ:** federation or quorum queues + 3 nodes.

## Monitoring
- NATS: `:8222/varz`
- Redis: redis_exporter (add as separate Nomad job, scrape Prometheus)
- RabbitMQ: built-in Prometheus endpoint at `:15692`
EOF
git add docs/runbooks/queues.md
git commit -m "docs(runbook): queues"
git push origin main
```

---

## Self-Review

- Audit #10 covered (3 of the canonical primitives).
- No placeholders.
- Type/name consistency: `<svc>.service.consul:<port>` URI shape uniform.
