#!/usr/bin/env bash
# scripts/components/dashboards/verify.sh
# Runs INSIDE the dashboards LXC. Exit 0 if healthy.

set -euo pipefail

fail=0

if ! systemctl is-active --quiet s3-bro-hunter 2>/dev/null; then
  echo '[verify] s3-bro-hunter service not active' >&2
  fail=1
fi

if ! systemctl is-active --quiet s3-playbook-forge 2>/dev/null; then
  echo '[verify] s3-playbook-forge service not active' >&2
  fail=1
fi

if ! systemctl is-active --quiet nginx 2>/dev/null; then
  echo '[verify] nginx service not active' >&2
  fail=1
fi

# HTTP reachability checks (2xx or 3xx acceptable)
check_http() {
  local label="$1"
  local url="$2"
  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null || true)"
  if [[ "${http_code}" =~ ^[23] ]]; then
    echo "[verify] ${label}: HTTP ${http_code} OK"
  else
    echo "[verify] ${label}: unexpected HTTP ${http_code} for ${url}" >&2
    fail=1
  fi
}

check_http "bro-hunter"     "http://localhost/bro-hunter/"
check_http "playbook-forge" "http://localhost/playbook-forge/"

exit "${fail}"
