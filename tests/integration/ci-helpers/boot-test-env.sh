#!/usr/bin/env bash
# tests/integration/ci-helpers/boot-test-env.sh <component>|all
#
# CI helper: SSH from the runner LXC to the Proxmox host, allocate a test VMID,
# run install.sh for the named component (or "all"), run the corresponding
# assertions. Exits non-zero on any failure.
#
# Required: GITHUB_WORKSPACE must be set (set automatically by GitHub Actions).
#
# Optional env:
#   PROXMOX_HOST - SSH target for the Proxmox host (default: gh-runner@proxmox)
#                  The 'proxmox' hostname must resolve inside the runner LXC via
#                  /etc/hosts or ~/.ssh/config. This is configured during
#                  setup-ci-runner.sh bootstrap.
#                  TODO: add the /etc/hosts entry to setup-ci-runner.sh so new
#                  runner LXCs get it automatically without manual setup.

set -euo pipefail

TARGET="${1:?usage: $0 <component>|all}"

# SSH alias target. 'proxmox' resolves to the Proxmox host inside the runner LXC
# via /etc/hosts (added by setup-ci-runner.sh) or the runner's ssh config.
PROXMOX_HOST="${PROXMOX_HOST:-gh-runner@proxmox}"
WORK_DIR="/tmp/soc-stack-ci-${TARGET}-$$"

log() { printf '[ci-boot] %s\n' "$*"; }

# Push the current checkout to the Proxmox host
log "rsyncing checkout to ${PROXMOX_HOST}:${WORK_DIR}"
# shellcheck disable=SC2029 # WORK_DIR and TARGET intentionally expand on the client side
ssh "${PROXMOX_HOST}" "mkdir -p '${WORK_DIR}'"
rsync -a --delete \
  --exclude='.git' --exclude='tests/vendor/bats-core/.git' \
  --exclude='tests/vendor/bats-support/.git' --exclude='tests/vendor/bats-assert/.git' \
  "${GITHUB_WORKSPACE}/" "${PROXMOX_HOST}:${WORK_DIR}/"

# Wipe any stale state from prior CI runs - matrix jobs share /tmp/soc-stack-test/
# and a left-behind state file would cause install.sh's idempotency check to skip
# the actual deploy and falsely claim success.
# (gh-runner sudoers allows bash, not rm directly, so wrap in sudo bash -c.)
# shellcheck disable=SC2029
ssh "${PROXMOX_HOST}" "sudo bash -c 'rm -f /tmp/soc-stack-test/state/${TARGET}.json /tmp/soc-stack-test/vmid-${TARGET}.txt'"

# Set up test env (allocates VMID)
# shellcheck disable=SC2029
ssh "${PROXMOX_HOST}" "sudo bash ${WORK_DIR}/tests/integration/setup-test-env.sh '${TARGET}'"

# Determine components flag and VMID
if [[ "${TARGET}" == "all" ]]; then
  COMPONENTS="wazuh,thehive-cortex,misp,zeek-suricata,dashboards,mcp"
  # shellcheck disable=SC2029
  VMID="$(ssh "${PROXMOX_HOST}" "cat /tmp/soc-stack-test/vmid-all.txt 2>/dev/null || cat /tmp/soc-stack-test/vmid-wazuh.txt")"
else
  COMPONENTS="${TARGET}"
  # shellcheck disable=SC2029
  VMID="$(ssh "${PROXMOX_HOST}" "cat /tmp/soc-stack-test/vmid-${TARGET}.txt")"
fi

# Run the install
# shellcheck disable=SC2029
ssh "${PROXMOX_HOST}" "sudo bash ${WORK_DIR}/scripts/install.sh \
  --components ${COMPONENTS} --preset minimal \
  --bridge vmbr0 --storage local-lvm --ip-mode dhcp \
  --vmid-start ${VMID} \
  --state-dir /tmp/soc-stack-test \
  --json-out /tmp/soc-stack-test/result.json \
  --mcp-config-out /tmp/soc-stack-test/mcp-clients.json \
  --log-file /tmp/soc-stack-test/install.log"

# Run assertions
if [[ "${TARGET}" == "all" ]]; then
  for c in wazuh thehive-cortex misp zeek-suricata dashboards mcp; do
    # shellcheck disable=SC2029
    ssh "${PROXMOX_HOST}" "bash ${WORK_DIR}/tests/integration/assert-${c}.sh /tmp/soc-stack-test/result.json"
  done
  # shellcheck disable=SC2029
  ssh "${PROXMOX_HOST}" "sudo bash ${WORK_DIR}/tests/integration/assert-all-integrations.sh /tmp/soc-stack-test/result.json"
else
  # shellcheck disable=SC2029
  ssh "${PROXMOX_HOST}" "bash ${WORK_DIR}/tests/integration/assert-${TARGET}.sh /tmp/soc-stack-test/result.json"
fi

log "PASS for ${TARGET}"
