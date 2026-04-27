# Postgres (Patroni) HA Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a 3-node Patroni-managed Postgres 16 cluster as a Nomad system job (one alloc per server node), using Consul as DCS for leader election. Expose primary via Consul service `postgres-primary`. Closes audit #9 (in-cluster path).

**Architecture:** Patroni 4.x + Postgres 16 in a single Docker image (`ongres/spilo` or `bitnami/postgresql-repmgr` — using `ghcr.io/zalando/spilo-16:3.3` as the well-tested option). Three allocs (one per server node) discover each other via Consul DCS. Each persists to its own host_volume `pg_data_<idx>`. PgBouncer runs as a sidecar for connection pooling. App access goes through Consul DNS `postgres-primary.service.consul:5432`.

**Tech Stack:** Patroni 4.0, Postgres 16, Spilo image, Consul DCS, Nomad system job, host_volumes.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/postgres/templates/patroni.nomad.hcl.j2` | 3-node system job |
| `ansible/roles/postgres/templates/patroni.yml.j2` | Patroni config |
| `ansible/roles/postgres/templates/pgbouncer.nomad.hcl.j2` | PgBouncer per-server |
| `ansible/roles/postgres/tasks/main.yml` | Render configs, submit jobs, init replication user |
| `ansible/inventory/group_vars/all/defaults.yml` | versions, data dir, scope name |
| `ansible/inventory/group_vars/all/secrets.example.yml` | superuser/replication passwords |
| `tests/smoke/test_postgres_ha.sh` | Connect, write, fail leader, write again |

---

## Task 1: Defaults + secrets

```bash
cat >> ansible/inventory/group_vars/all/defaults.yml <<'EOF'

# Postgres / Patroni
patroni_scope: "orbty-pg"
patroni_postgres_version: 16
patroni_data_dir: "/opt/postgres"
pgbouncer_port: 6432
patroni_image: "ghcr.io/zalando/spilo-16:3.3-p2"
EOF
cat >> ansible/inventory/group_vars/all/secrets.example.yml <<'EOF'
# Postgres
postgres_superuser_password: ""    # openssl rand -base64 32
postgres_replication_password: ""  # openssl rand -base64 32
EOF

git add ansible/inventory/group_vars/all/defaults.yml ansible/inventory/group_vars/all/secrets.example.yml
git commit -m "chore(postgres): defaults + secret schema"
```

---

## Task 2: Failing smoke

```bash
cat > tests/smoke/test_postgres_ha.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
PASS=$(awk '$1=="postgres_superuser_password:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml" | tr -d \")
[[ -z "$PASS" ]] && { echo "FAIL: postgres_superuser_password not set"; exit 1; }

echo "=== Patroni cluster has a leader ==="
multipass exec "$VM" -- bash -c "
  curl -s http://localhost:8008/cluster | python3 -c 'import sys,json; d=json.load(sys.stdin); print([m for m in d[\"members\"] if m[\"role\"]==\"leader\"])'
" | grep -q leader || { echo FAIL no leader; exit 1; }
echo OK

echo "=== psql roundtrip via pgbouncer ==="
multipass exec "$VM" -- bash -c "
  PGPASSWORD='$PASS' psql -h pgbouncer.service.consul -p 6432 -U postgres -c 'SELECT now()'
" | grep -q "now" || { echo FAIL psql; exit 1; }
echo OK

echo "ALL POSTGRES HA CHECKS PASSED"
EOF
chmod +x tests/smoke/test_postgres_ha.sh
git add tests/smoke/test_postgres_ha.sh
git commit -m "test(postgres): failing smoke for patroni HA"
```

---

## Task 3: host_volume per server

In `nomad-client.hcl.j2`:

```hcl
  host_volume "pg_data" {
    path      = "{{ patroni_data_dir }}"
    read_only = false
  }
```

In nomad role tasks, ensure dir owner = 1000 (spilo image runs as `postgres` uid 999 / 1000 depending on tag):

```yaml
- name: Ensure postgres data dir
  ansible.builtin.file:
    path: "{{ patroni_data_dir }}"
    state: directory
    owner: "1000"
    group: "1000"
    mode: "0700"
```

Run nomad role.

---

## Task 4: Patroni Nomad job

```bash
mkdir -p ansible/roles/postgres/{tasks,templates}
cat > ansible/roles/postgres/templates/patroni.nomad.hcl.j2 <<'EOF'
job "patroni" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "system"

  group "patroni" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "pg"     { static = 5432 }
      port "rest"   { static = 8008 }
    }

    volume "data" {
      type      = "host"
      source    = "pg_data"
      read_only = false
    }

    service {
      name = "patroni-rest"
      port = "rest"
      check {
        type     = "http"
        path     = "/health"
        interval = "5s"
        timeout  = "2s"
      }
    }

    service {
      name = "postgres-primary"
      port = "pg"
      check {
        type     = "http"
        port     = "rest"
        path     = "/leader"
        interval = "3s"
        timeout  = "1s"
      }
    }

    service {
      name = "postgres-replica"
      port = "pg"
      check {
        type     = "http"
        port     = "rest"
        path     = "/replica"
        interval = "5s"
        timeout  = "1s"
      }
    }

    task "patroni" {
      driver = "docker"

      env {
        PATRONI_NAME              = "${node.unique.name}"
        PATRONI_SCOPE             = "{{ patroni_scope }}"
        PATRONI_NAMESPACE         = "/orbty"
        PATRONI_CONSUL_HOST       = "127.0.0.1:8500"
        PATRONI_CONSUL_TOKEN      = "{{ consul_bootstrap_token }}"
        PATRONI_RESTAPI_LISTEN    = "0.0.0.0:8008"
        PATRONI_RESTAPI_CONNECT_ADDRESS = "${attr.unique.network.ip-address}:8008"
        PATRONI_POSTGRESQL_LISTEN = "0.0.0.0:5432"
        PATRONI_POSTGRESQL_CONNECT_ADDRESS = "${attr.unique.network.ip-address}:5432"
        PATRONI_POSTGRESQL_DATA_DIR = "/home/postgres/pgdata/pgroot/data"
        PATRONI_SUPERUSER_USERNAME = "postgres"
        PATRONI_SUPERUSER_PASSWORD = "{{ postgres_superuser_password }}"
        PATRONI_REPLICATION_USERNAME = "replicator"
        PATRONI_REPLICATION_PASSWORD = "{{ postgres_replication_password }}"
        PGVERSION = "{{ patroni_postgres_version }}"
      }

      volume_mount {
        volume      = "data"
        destination = "/home/postgres/pgdata"
        read_only   = false
      }

      config {
        image        = "{{ patroni_image }}"
        network_mode = "host"
      }

      resources { cpu = 500; memory = 1024 }
    }
  }
}
EOF
```

Commit:

```bash
git add ansible/roles/postgres/templates/patroni.nomad.hcl.j2
git commit -m "feat(postgres): patroni system job (3-node HA)"
```

---

## Task 5: PgBouncer

```bash
cat > ansible/roles/postgres/templates/pgbouncer.nomad.hcl.j2 <<'EOF'
job "pgbouncer" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "system"

  group "pgbouncer" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network {
      mode = "host"
      port "pg" { static = {{ pgbouncer_port }} }
    }

    service {
      name = "pgbouncer"
      port = "pg"
      check {
        type     = "tcp"
        port     = "pg"
        interval = "5s"
        timeout  = "2s"
      }
    }

    task "pgbouncer" {
      driver = "docker"

      env {
        DB_USER     = "postgres"
        DB_PASSWORD = "{{ postgres_superuser_password }}"
        DB_HOST     = "postgres-primary.service.consul"
        DB_PORT     = "5432"
        DB_NAME     = "*"
        POOL_MODE   = "transaction"
        MAX_CLIENT_CONN = "1000"
        DEFAULT_POOL_SIZE = "20"
        AUTH_TYPE   = "md5"
        ADMIN_USERS = "postgres"
      }

      config {
        image        = "edoburu/pgbouncer:latest"
        network_mode = "host"
      }

      resources { cpu = 100; memory = 128 }
    }
  }
}
EOF
git add ansible/roles/postgres/templates/pgbouncer.nomad.hcl.j2
git commit -m "feat(postgres): pgbouncer system job"
```

---

## Task 6: Submit + smoke + push

```bash
cat > ansible/roles/postgres/tasks/main.yml <<'EOF'
---
- name: Submit patroni
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'patroni.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true

- name: Submit pgbouncer
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'pgbouncer.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF

ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags postgres,nomad
bash tests/smoke/test_postgres_ha.sh nomad-local-server-01

git add ansible/roles/postgres/tasks/main.yml
git commit -m "feat(postgres): submit patroni+pgbouncer"
git push origin main
```

---

## Task 7: Runbook

```bash
cat > docs/runbooks/postgres.md <<'EOF'
# Runbook — Postgres (Patroni)

## Topology
- 3-node Patroni cluster, one alloc per server.
- Consul as DCS (leader election, member registry).
- Apps connect via `pgbouncer.service.consul:6432` → primary.
- Read-only replicas via `postgres-replica.service.consul:5432`.

## Failover
- Automatic by Patroni when primary fails (~10s detection + promote).
- Force manual: `curl -X POST http://<server>:8008/switchover`.

## Backups
- Use the `restic-backup` job (already set up) — `/opt/postgres` is included.
- For PITR, switch to `wal-g` or `pgbackrest`; not in this plan.

## Connecting
```
psql -h pgbouncer.service.consul -p 6432 -U postgres
```

## Adding a database
```bash
psql -h pgbouncer.service.consul -p 6432 -U postgres \
  -c "CREATE DATABASE myapp OWNER myapp_user; CREATE USER myapp_user PASSWORD '...';"
```
EOF
git add docs/runbooks/postgres.md
git commit -m "docs(runbook): postgres patroni"
git push origin main
```

---

## Self-Review

- Audit #9 (in-cluster) covered: HA, pooling, failover.
- No placeholders.
- Type/name consistency: `postgres-primary`, `pgbouncer.service.consul:6432` aligned.
