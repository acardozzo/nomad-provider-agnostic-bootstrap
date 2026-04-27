#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALL="$ROOT_DIR/ansible/inventory/group_vars/all/defaults.yml"
SECRETS="$ROOT_DIR/ansible/inventory/group_vars/all/secrets.yml"

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
