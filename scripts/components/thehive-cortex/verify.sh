#!/usr/bin/env bash
# scripts/components/thehive-cortex/verify.sh
# Runs INSIDE the LXC. Exit 0 if healthy.

set -euo pipefail

fail=0
# shellcheck disable=SC2034
IP="$(hostname -I | awk '{print $1}')"

for svc_url in \
  "http://localhost:9000/api/status" \
  "http://localhost:9001/api/status" \
; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${svc_url}")"
  if [[ "${code}" -lt 200 || "${code}" -ge 500 ]]; then
    printf '[verify] %s -> HTTP %s\n' "${svc_url}" "${code}" >&2
    fail=1
  fi
done

# Compose-level health
if ! docker compose -f /opt/soc-stack/thehive-cortex/docker-compose.yml ps 2>/dev/null \
     | grep -E '(thehive|cortex)' | grep -q running; then
  echo '[verify] one or more compose services not running' >&2
  fail=1
fi

exit "${fail}"
