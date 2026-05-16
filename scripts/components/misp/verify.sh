#!/usr/bin/env bash
# scripts/components/misp/verify.sh
# Runs INSIDE the misp LXC. Exit 0 if healthy.

set -euo pipefail

fail=0

code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://localhost/users/heartbeat")"
if [[ "${code}" -lt 200 || "${code}" -ge 500 ]]; then
  printf '[verify] https://localhost/users/heartbeat returned HTTP %s\n' "${code}" >&2
  fail=1
fi

if ! docker compose -f /opt/soc-stack/misp/docker-compose.yml ps \
       --filter "status=running" --services 2>/dev/null \
     | grep -qx "misp-core"; then
  echo '[verify] misp-core service not running' >&2
  fail=1
fi

exit "${fail}"
