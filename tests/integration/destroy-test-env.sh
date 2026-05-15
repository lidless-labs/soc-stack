#!/usr/bin/env bash
# tests/integration/destroy-test-env.sh <component>|--all
# Tears down test LXCs in the 9000-9099 VMID range.

set -euo pipefail
TARGET="${1:-}"
[[ -n "${TARGET}" ]] || { echo "usage: $0 <component>|--all" >&2; exit 64; }

[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

TEST_STATE_DIR="/tmp/soc-stack-test"

destroy_vmid() {
  local vmid="$1"
  pct stop "${vmid}" 2>/dev/null || true
  pct destroy "${vmid}" 2>/dev/null || true
  echo "destroyed LXC ${vmid}"
}

if [[ "${TARGET}" == "--all" ]]; then
  for vmid in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    if (( vmid >= 9000 && vmid <= 9099 )); then
      destroy_vmid "${vmid}"
    fi
  done
  rm -rf "${TEST_STATE_DIR}"
  exit 0
fi

# Single-component teardown
vmid_file="${TEST_STATE_DIR}/vmid-${TARGET}.txt"
if [[ -f "${vmid_file}" ]]; then
  destroy_vmid "$(cat "${vmid_file}")"
  rm -f "${vmid_file}"
fi
rm -f "${TEST_STATE_DIR}/state/${TARGET}.json"
