#!/usr/bin/env bash
# tests/integration/setup-test-env.sh <component>
# Prepares an isolated test environment on a Proxmox host:
#   - Picks the next free VMID in 9000-9099 range
#   - Ensures /tmp/soc-stack-test/ scratch dir exists
#
# Must run as root on a Proxmox host.

set -euo pipefail
COMPONENT="${1:-}"
[[ -n "${COMPONENT}" ]] || { echo "usage: $0 <component>" >&2; exit 64; }

TEST_VMID_RANGE_START=9000
TEST_VMID_RANGE_END=9099
TEST_STATE_DIR="/tmp/soc-stack-test"

# Sanity: must be root + Proxmox host
[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not on PATH - not a Proxmox host?" >&2; exit 1; }

mkdir -p "${TEST_STATE_DIR}/state" "${TEST_STATE_DIR}/secrets" "${TEST_STATE_DIR}/logs"

# Find a free VMID in the test range
used_ids="$( (pct list 2>/dev/null | awk 'NR>1 {print $1}'; qm list 2>/dev/null | awk 'NR>1 {print $1}') | sort -u)"
candidate="${TEST_VMID_RANGE_START}"
while (( candidate <= TEST_VMID_RANGE_END )); do
  if ! grep -qx "${candidate}" <<< "${used_ids}"; then
    echo "${candidate}" > "${TEST_STATE_DIR}/vmid-${COMPONENT}.txt"
    echo "test VMID for ${COMPONENT}: ${candidate}"
    exit 0
  fi
  candidate=$((candidate + 1))
done
echo "no free VMIDs in ${TEST_VMID_RANGE_START}-${TEST_VMID_RANGE_END}" >&2
exit 1
