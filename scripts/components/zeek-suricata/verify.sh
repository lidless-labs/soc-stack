#!/usr/bin/env bash
# scripts/components/zeek-suricata/verify.sh
# Runs INSIDE the zeek-suricata LXC. Exit 0 if healthy.

set -euo pipefail

fail=0

if ! systemctl is-active --quiet zeek 2>/dev/null; then
  echo '[verify] zeek service not active' >&2
  fail=1
fi
if ! systemctl is-active --quiet suricata 2>/dev/null; then
  echo '[verify] suricata service not active' >&2
  fail=1
fi

# Log dirs should exist (log files appear after first traffic - tolerate empty)
[[ -d /opt/zeek/logs ]] || { echo '[verify] /opt/zeek/logs missing' >&2; fail=1; }
[[ -d /var/log/suricata ]] || { echo '[verify] /var/log/suricata missing' >&2; fail=1; }

exit "${fail}"
