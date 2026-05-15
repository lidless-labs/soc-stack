#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_STATE_DIR}/state"
  source_lib logging
  source "${REPO_ROOT}/scripts/lib/json-out.sh"
  source_lib idempotency
}

@test "is_completed returns false for missing state" {
  run is_completed wazuh
  [[ "$status" -ne 0 ]]
}

@test "is_completed returns false when status is not deployed" {
  state_set wazuh status "failed"
  run is_completed wazuh
  [[ "$status" -ne 0 ]]
}

@test "is_completed returns true when status is deployed" {
  state_set wazuh status "deployed"
  run is_completed wazuh
  [[ "$status" -eq 0 ]]
}

@test "mark_completed sets status to deployed" {
  mark_completed wazuh
  run state_get wazuh status
  assert_output "deployed"
}

@test "clear_state removes the state file" {
  state_set wazuh status "deployed"
  clear_state wazuh
  [[ ! -f "${SOC_STATE_DIR}/state/wazuh.json" ]]
}

@test "clear_state on missing state is a no-op" {
  run clear_state "does-not-exist"
  [[ "$status" -eq 0 ]]
}
