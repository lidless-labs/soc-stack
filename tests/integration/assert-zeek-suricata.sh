#!/usr/bin/env bash
# tests/integration/assert-zeek-suricata.sh <result-json>
# Verifies Zeek + Suricata deployment.
#
# Checks:
#   1. Result JSON has zeek-suricata component with status=deployed
#   2. State JSON has zeek.log_dir and suricata.eve_path populated
#   3. If pct is available (Proxmox host): systemctl is-active zeek AND suricata in the LXC
#      Otherwise: gracefully degrades to state-JSON-only verification

set -euo pipefail

RESULT="${1:-}"
[[ -n "${RESULT}" ]] || { echo "usage: $0 <result-json>" >&2; exit 64; }
[[ -f "${RESULT}" ]] || { echo "result file not found: ${RESULT}" >&2; exit 2; }

log()  { printf '[assert-zs] %s\n' "$*"; }
fail() { printf '[assert-zs] FAIL: %s\n' "$*" >&2; exit 1; }

log "verifying ${RESULT}"

# Check 1: status
status="$(jq -r '.components[] | select(.name == "zeek-suricata") | .status' "${RESULT}")"
[[ "${status}" == "deployed" ]] || fail "zeek-suricata status='${status}', expected 'deployed'"
log "status=deployed"

# Check 2: state JSON fields populated
log_dir="$(jq -r '.components[] | select(.name == "zeek-suricata") | .zeek.log_dir // empty' "${RESULT}")"
eve_path="$(jq -r '.components[] | select(.name == "zeek-suricata") | .suricata.eve_path // empty' "${RESULT}")"
[[ -n "${log_dir}" && "${log_dir}" != "null" ]]   || fail "zeek.log_dir missing in result JSON"
[[ -n "${eve_path}" && "${eve_path}" != "null" ]] || fail "suricata.eve_path missing in result JSON"
log "zeek.log_dir=${log_dir}"
log "suricata.eve_path=${eve_path}"

# Check 3: in-LXC service state (requires pct, i.e. Proxmox host)
if command -v pct >/dev/null 2>&1; then
  vmid="$(jq -r '.components[] | select(.name == "zeek-suricata") | .lxc.vmid // empty' "${RESULT}")"
  [[ -n "${vmid}" && "${vmid}" != "null" ]] || fail "lxc.vmid missing in result JSON (needed for pct exec)"
  log "checking zeek-suricata LXC (vmid=${vmid}) via pct exec"

  if pct exec "${vmid}" -- systemctl is-active --quiet zeek 2>/dev/null; then
    log "zeek systemd unit active"
  else
    fail "zeek not active in LXC ${vmid}"
  fi

  if pct exec "${vmid}" -- systemctl is-active --quiet suricata 2>/dev/null; then
    log "suricata systemd unit active"
  else
    fail "suricata not active in LXC ${vmid}"
  fi
else
  log "pct not available; skipping in-LXC service check (state-only verification)"
fi

log "PASS"
