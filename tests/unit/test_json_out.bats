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
  state_set wazuh url "https://198.51.100.10"
  jq -e '.status == "deployed" and .url == "https://198.51.100.10"' "${SOC_STATE_DIR}/state/wazuh.json"
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
  state_set wazuh url "https://198.51.100.10"
  state_set wazuh "credentials.password" "secret-password"
  state_set misp  status "failed"
  state_set misp  error "compose pull timeout"

  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"

  jq -e '.version == "1.0"' "${out}"
  jq -e '.components | length == 2' "${out}"
  jq -e '.components[] | select(.name == "wazuh") | .status == "deployed"' "${out}"
  jq -e '.components[] | select(.name == "wazuh") | .credentials.password == "REDACTED"' "${out}"
  jq -e '.components[] | select(.name == "misp")  | .status == "failed"' "${out}"
}

@test "emit_final_json includes installed_at ISO timestamp" {
  state_set wazuh status "deployed"
  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"
  jq -e '.installed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "${out}"
}

@test "emit_final_json includes raw secrets only when explicitly requested" {
  state_set wazuh status "deployed"
  state_set wazuh "credentials.password" "secret-password"
  local out="${BATS_TEST_TMPDIR}/result.json"

  emit_final_json "${out}" 1

  jq -e '.components[] | select(.name == "wazuh") | .credentials.password == "secret-password"' "${out}"
}

@test "emit_final_json records warning array from environment" {
  state_set mcp status "deployed"
  local out="${BATS_TEST_TMPDIR}/result.json"

  SOC_WARNINGS_JSON='["mcp selected without wazuh"]' emit_final_json "${out}"

  jq -e '.warnings[0] == "mcp selected without wazuh"' "${out}"
}

@test "emit_final_json writes mode 0600 output" {
  state_set wazuh status "deployed"
  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"

  local mode
  mode="$(stat -c "%a" "${out}")"
  [[ "${mode}" == "600" ]]
}

@test "state_set does not destroy state when the existing file is corrupt" {
  local f="${SOC_STATE_DIR}/state/wazuh.json"
  printf '{ this is not valid json' > "${f}"
  run state_set wazuh status "deployed"
  assert_success
  jq -e . "${f}"                        # parses again
  jq -e '.status == "deployed"' "${f}"  # the update landed
}

@test "state_get returns empty on a corrupt state file without aborting" {
  printf '{ broken' > "${SOC_STATE_DIR}/state/wazuh.json"
  run state_get wazuh status
  assert_success
  assert_output ""
}

@test "redact_json redacts broadened key names and url-embedded credentials" {
  local input='{"pwd":"a","bearer":"b","credential":"c","passwd":"d","endpoint":"https://user:secretpass@host:9000/x","ok":"plain"}'
  local out
  out="$(printf '%s' "${input}" | redact_json)"
  jq -e '.pwd == "REDACTED"'        <<< "${out}"
  jq -e '.bearer == "REDACTED"'     <<< "${out}"
  jq -e '.credential == "REDACTED"' <<< "${out}"
  jq -e '.passwd == "REDACTED"'     <<< "${out}"
  jq -e '.ok == "plain"'            <<< "${out}"
  jq -e '.endpoint | contains("REDACTED@host")' <<< "${out}"
  jq -e '.endpoint | contains("secretpass") | not' <<< "${out}"
}

@test "emit_final_json redacts mcp endpoint bearer tokens by default" {
  state_set mcp status "deployed"
  state_set mcp mcp_endpoints '[{"name":"wazuh","url":"http://127.0.0.1:9101/sse","token":"deadbeeftoken"}]'
  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}"
  jq -e '.components[] | select(.name=="mcp") | .mcp_endpoints[0].token == "REDACTED"' "${out}"
  run grep -q "deadbeeftoken" "${out}"
  assert_failure
}

@test "emit_final_json keeps mcp endpoint tokens raw when secrets are requested" {
  state_set mcp status "deployed"
  state_set mcp mcp_endpoints '[{"name":"wazuh","url":"http://127.0.0.1:9101/sse","token":"deadbeeftoken"}]'
  local out="${BATS_TEST_TMPDIR}/result.json"
  emit_final_json "${out}" 1
  jq -e '.components[] | select(.name=="mcp") | .mcp_endpoints[0].token == "deadbeeftoken"' "${out}"
}
