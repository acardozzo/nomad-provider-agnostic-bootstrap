#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the Traefik docker-compose stack (dev/docker/compose.yml).
# Uses host ports 8080/8443 to avoid clashing with anything on 80/443.

HTTP="http://127.0.0.1:18080"
HTTPS="https://127.0.0.1:18443"

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
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: cluster.local' "$HTTP/whoami")
  [[ "$code" == "301" || "$code" == "302" || "$code" == "307" || "$code" == "308" ]]
}
retry 30 2 check_redirect || { echo "FAIL: HTTP did not redirect"; exit 1; }
echo "OK"

echo "=== whoami: HTTPS must return 200 (self-signed accepted with -k) ==="
check_200() {
  code=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Host: cluster.local' "$HTTPS/whoami")
  [[ "$code" == "200" ]]
}
retry 30 2 check_200 || { echo "FAIL: HTTPS /whoami did not return 200"; exit 1; }
echo "OK"

echo "=== whoami: response body contains the path we expect ==="
body=$(curl -sk -H 'Host: cluster.local' "$HTTPS/whoami")
echo "$body" | grep -q "Hostname:" && echo "OK" || { echo "FAIL: unexpected body"; echo "$body"; exit 1; }

echo "=== dashboard: HTTPS routing works (Traefik returns 401 or 200 on api/) ==="
code=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Host: traefik.cluster.local' "$HTTPS/api/overview")
if [[ "$code" != "200" && "$code" != "401" ]]; then
  echo "FAIL: dashboard host did not route, got $code"
  exit 1
fi
echo "OK ($code — note: this compose file does not enable basic-auth; production does)"

echo ""
echo "ALL LOCAL TRAEFIK SMOKE CHECKS PASSED"
