#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TRAEFIK_JOB="$ROOT_DIR/ansible/roles/traefik/templates/traefik.nomad.hcl.j2"
SAMPLE_APP_TASKS="$ROOT_DIR/ansible/roles/sample_app/tasks/main.yml"
SAMPLE_APP_JOB="$ROOT_DIR/ansible/roles/sample_app/templates/whoami.nomad.hcl.j2"
BOOTSTRAP_PLAYBOOK="$ROOT_DIR/ansible/playbooks/bootstrap.yml"

[[ -f "$TRAEFIK_JOB" ]]
[[ -f "$SAMPLE_APP_TASKS" ]]
[[ -f "$SAMPLE_APP_JOB" ]]

grep -q 'providers.consulcatalog.endpoint.address=127.0.0.1:8500' "$TRAEFIK_JOB"
grep -q 'providers.consulcatalog.exposedByDefault=false' "$TRAEFIK_JOB"
grep -q 'sample_app' "$BOOTSTRAP_PLAYBOOK"
grep -q 'traefik.enable=true' "$SAMPLE_APP_JOB"
grep -q 'traefik.http.routers.whoami.rule=PathPrefix(`/whoami`)' "$SAMPLE_APP_JOB"
grep -q 'traefik.http.middlewares.whoami-strip.stripprefix.prefixes=/whoami' "$SAMPLE_APP_JOB"

echo "Ingress assets look wired correctly."
