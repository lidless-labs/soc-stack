#!/usr/bin/env bash
# scripts/components/wazuh/verify.sh
# Runs INSIDE the Wazuh LXC. Returns 0 if healthy.

set -euo pipefail

fail=0
for svc in wazuh-manager wazuh-indexer wazuh-dashboard; do
  if ! systemctl is-active --quiet "${svc}"; then
    printf '[verify] %s is not active\n' "${svc}" >&2
    fail=1
  fi
done

# Dashboard HTTPS responds
IP="$(hostname -I | awk '{print $1}')"
if ! curl -sk --max-time 10 "https://${IP}/" >/dev/null; then
  printf '[verify] dashboard https://%s/ did not respond\n' "${IP}" >&2
  fail=1
fi

# API responds (401 is fine - means service is up)
api_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${IP}:55000/")"
if [[ "${api_code}" -lt 200 || "${api_code}" -ge 600 ]]; then
  printf '[verify] API https://%s:55000/ returned %s\n' "${IP}" "${api_code}" >&2
  fail=1
fi

exit "${fail}"
