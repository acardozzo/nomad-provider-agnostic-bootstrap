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
SECRETS="$ROOT_DIR/ansible/inventory/group_vars/all/secrets.yml"

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
