#!/usr/bin/env bats
# The per-component destroy.sh scripts are the teardown side of the contract and
# previously had no coverage. wazuh/destroy.sh is representative of the pattern
# (read state file -> pct stop/destroy the VMID -> remove state file).

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  mkdir -p "${SOC_STATE_DIR}/state"
  : > "${MOCK_PCT_CALLS_LOG}"
}

@test "wazuh destroy is a no-op when no state file exists" {
  run bash "${REPO_ROOT}/scripts/components/wazuh/destroy.sh"
  assert_success
  [[ ! -s "${MOCK_PCT_CALLS_LOG}" ]]   # no pct calls at all
}

@test "wazuh destroy stops and destroys the LXC and removes the state file" {
  printf '%s' '{"lxc":{"vmid":9007},"status":"deployed"}' > "${SOC_STATE_DIR}/state/wazuh.json"
  run bash "${REPO_ROOT}/scripts/components/wazuh/destroy.sh"
  assert_success
  grep -q "pct stop 9007" "${MOCK_PCT_CALLS_LOG}"
  grep -q "pct destroy 9007" "${MOCK_PCT_CALLS_LOG}"
  [[ ! -f "${SOC_STATE_DIR}/state/wazuh.json" ]]
}

@test "wazuh destroy removes the state file even when it records no VMID" {
  printf '%s' '{"status":"failed"}' > "${SOC_STATE_DIR}/state/wazuh.json"
  run bash "${REPO_ROOT}/scripts/components/wazuh/destroy.sh"
  assert_success
  run grep -q "pct destroy" "${MOCK_PCT_CALLS_LOG}"
  assert_failure   # nothing to destroy without a VMID
  [[ ! -f "${SOC_STATE_DIR}/state/wazuh.json" ]]
}
