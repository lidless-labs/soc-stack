#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_STATE_DIR}/state"
  source_lib logging
  source_lib json_out 2>/dev/null || source "${REPO_ROOT}/scripts/lib/json-out.sh"
}

@test "state_set creates state file if missing" {
  state_set wazuh status "deployed"
  [[ -f "${SOC_STATE_DIR}/state/wazuh.json" ]]
  jq -e '.status == "deployed"' "${SOC_STATE_DIR}/state/wazuh.json"
}

@test "state_set updates existing field without losing others" {
  state_set wazuh status "deployed"
  state_set wazuh url "https://10.0.50.10"
  jq -e '.status == "deployed" and .url == "https://10.0.50.10"' "${SOC_STATE_DIR}/state/wazuh.json"
}

@test "state_set handles nested keys via dot notation" {
  state_set wazuh "lxc.vmid" 201
  jq -e '.lxc.vmid == 201' "${SOC_STATE_DIR}/state/wazuh.json"
}

@test "state_get reads a field" {
  state_set wazuh status "deployed"
  run state_get wazuh status
  assert_success
  assert_output "deployed"
}

@test "state_get on missing field returns empty" {
  state_set wazuh status "deployed"
  run state_get wazuh "missing"
  assert_success
  assert_output ""
}

@test "state_get on missing component returns empty" {
  run state_get "does-not-exist" status
  assert_success
  assert_output ""
}

@test "emit_final_json writes valid JSON with all component states" {
  state_set wazuh status "deployed"
  state_set wazuh url "https://10.0.50.10"
  state_set misp  status "failed"
  state_set misp  error "compose pull timeout"

  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"

  jq -e '.version == "1.0"' "${out}"
  jq -e '.components | length == 2' "${out}"
  jq -e '.components[] | select(.name == "wazuh") | .status == "deployed"' "${out}"
  jq -e '.components[] | select(.name == "misp")  | .status == "failed"' "${out}"
}

@test "emit_final_json includes installed_at ISO timestamp" {
  state_set wazuh status "deployed"
  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"
  jq -e '.installed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "${out}"
}
