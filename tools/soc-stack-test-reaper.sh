#!/usr/bin/env bash
# tools/soc-stack-test-reaper.sh
# Runs every 15 min on the Proxmox host via /etc/cron.d/soc-stack-test-reaper.
# Destroys any LXC in VMID 9000-9099 older than 90 minutes.
# Test-only - production LXCs (100-9000, 9100+) are untouched.

set -euo pipefail

LOG=/var/log/soc-stack-test-reaper.log
MAX_AGE_MIN=90

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "${LOG}"; }

now=$(date +%s)
threshold=$(( now - MAX_AGE_MIN * 60 ))

pct list 2>/dev/null | awk 'NR>1' | while read -r vmid _ _; do
  if (( vmid >= 9000 && vmid <= 9099 )); then
    conf="/etc/pve/lxc/${vmid}.conf"
    if [[ -f "${conf}" ]]; then
      mtime=$(stat -c %Y "${conf}")
      if (( mtime < threshold )); then
        log "reaping LXC ${vmid} (mtime=${mtime}, threshold=${threshold})"
        pct stop "${vmid}" 2>/dev/null || true
        pct destroy "${vmid}" 2>/dev/null || true
      fi
    fi
  fi
done
