#!/usr/bin/env bash
# tests/integration/ci-helpers/teardown-test-env.sh <component>|--all
#
# CI helper: always destroys test LXCs (whether the test passed or failed).
# Called with "if: always()" in the workflow so it runs even after boot failures.
#
# Optional env:
#   PROXMOX_HOST - SSH target for the Proxmox host (default: gh-runner@proxmox)
#                  Must resolve inside the runner LXC. See boot-test-env.sh.

set -euo pipefail

TARGET="${1:?usage: $0 <component>|--all}"
PROXMOX_HOST="${PROXMOX_HOST:-gh-runner@proxmox}"
WORK_DIR="/tmp/soc-stack-ci-${TARGET}-$$"

log() { printf '[ci-teardown] %s\n' "$*"; }

log "tearing down ${TARGET} on ${PROXMOX_HOST}"

# Try the structured destroy first. If that fails (e.g., rsync never completed
# so WORK_DIR does not exist), fall back to a range sweep of the test VMID band.
# SC2029: WORK_DIR and TARGET intentionally expand on the client side.
# shellcheck disable=SC2029
ssh "${PROXMOX_HOST}" "
  if [[ -f '${WORK_DIR}/tests/integration/destroy-test-env.sh' ]]; then
    sudo bash '${WORK_DIR}/tests/integration/destroy-test-env.sh' '${TARGET}' 2>/dev/null || true
  fi
  pct list 2>/dev/null | awk 'NR>1 && \$1+0 >= 9000 && \$1+0 <= 9099 {print \$1}' \
    | xargs -r -I{} bash -c 'pct stop {} 2>/dev/null; pct destroy {} 2>/dev/null' || true
" || true

log "teardown complete for ${TARGET}"
