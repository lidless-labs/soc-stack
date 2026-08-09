#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  export COMPONENTS_DIR="${REPO_ROOT}/scripts/components"
  export MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}"
  : > "${MOCK_PCT_CALLS_LOG}"

  source_lib logging
  source "${REPO_ROOT}/scripts/lib/json-out.sh"
  source_lib idempotency
  source_lib lxc
  source_lib health
}

@test "health_check_artifact reports missing required artifact" {
  run health_check_artifact result_json "${BATS_TEST_TMPDIR}/missing.json" 1
  assert_success
  jq -e '.status == "missing" and .exists == false and .required == true' <<< "${output}"
}

@test "health_check_artifact reports malformed JSON" {
  local path="${BATS_TEST_TMPDIR}/bad.json"
  printf 'not-json\n' > "${path}"
  run health_check_artifact result_json "${path}" 1
  assert_success
  jq -e '.status == "malformed" and .exists == true and .valid_json == false' <<< "${output}"
}

@test "health_check_artifact reports ok for valid JSON" {
  local path="${BATS_TEST_TMPDIR}/ok.json"
  printf '{"version":"1.0"}\n' > "${path}"
  run health_check_artifact result_json "${path}" 1
  assert_success
  jq -e '.status == "ok" and .valid_json == true' <<< "${output}"
}

@test "health_probe_component: running LXC with failed verify is unhealthy" {
  state_set wazuh status "deployed"
  state_set wazuh "lxc.vmid" 201
  state_set wazuh "lxc.hostname" "s3-wazuh"
  state_set wazuh "integration.status" "integrated"

  export MOCK_PCT_STATUS=running
  export MOCK_PCT_EXIT=0
  export MOCK_PCT_VERIFY_EXIT=1

  run health_probe_component wazuh
  assert_success
  jq -e '
    .lxc.running == true
    and .verify.status == "fail"
    and .observed_status == "unhealthy"
  ' <<< "${output}"
}

@test "health_probe_component: running LXC with passing verify is healthy" {
  state_set wazuh status "deployed"
  state_set wazuh "lxc.vmid" 201
  state_set wazuh "integration.status" "integrated"

  export MOCK_PCT_STATUS=running
  export MOCK_PCT_EXIT=0
  export MOCK_PCT_VERIFY_EXIT=0

  run health_probe_component wazuh
  assert_success
  jq -e '
    .lxc.running == true
    and .verify.status == "pass"
    and .observed_status == "healthy"
  ' <<< "${output}"
}

@test "health_probe_component: stopped LXC is unhealthy without claiming verify pass" {
  state_set wazuh status "deployed"
  state_set wazuh "lxc.vmid" 201

  export MOCK_PCT_STATUS=stopped
  export MOCK_PCT_EXIT=0

  run health_probe_component wazuh
  assert_success
  jq -e '
    .lxc.running == false
    and .verify.status == "skipped"
    and .observed_status == "unhealthy"
  ' <<< "${output}"
}

@test "emit_health_report: missing result artifact prevents overall healthy" {
  state_set wazuh status "deployed"
  state_set wazuh "lxc.vmid" 201
  state_set wazuh "integration.status" "integrated"

  export MOCK_PCT_STATUS=running
  export MOCK_PCT_VERIFY_EXIT=0

  local out="${BATS_TEST_TMPDIR}/health.json"
  local missing_result="${BATS_TEST_TMPDIR}/no-result.json"
  run emit_health_report "${out}" "wazuh" "${missing_result}" "${BATS_TEST_TMPDIR}/no-mcp.json"
  [[ "$status" -eq 1 ]]
  jq -e '
    .overall_status == "unhealthy"
    and (.artifacts[] | select(.name == "result_json") | .status == "missing")
    and (.components[] | select(.name == "wazuh") | .observed_status == "healthy")
  ' "${out}"
}

@test "emit_health_report: malformed result artifact prevents overall healthy" {
  state_set wazuh status "deployed"
  state_set wazuh "lxc.vmid" 201
  state_set wazuh "integration.status" "integrated"

  export MOCK_PCT_STATUS=running
  export MOCK_PCT_VERIFY_EXIT=0

  local out="${BATS_TEST_TMPDIR}/health.json"
  local bad_result="${BATS_TEST_TMPDIR}/bad-result.json"
  printf '{{{' > "${bad_result}"

  run emit_health_report "${out}" "wazuh" "${bad_result}" "${BATS_TEST_TMPDIR}/no-mcp.json"
  [[ "$status" -eq 1 ]]
  jq -e '
    .overall_status == "unhealthy"
    and (.artifacts[] | select(.name == "result_json") | .status == "malformed")
  ' "${out}"
}

@test "emit_health_report: healthy stack with valid artifacts exits 0" {
  state_set wazuh status "deployed"
  state_set wazuh "lxc.vmid" 201
  state_set wazuh "integration.status" "integrated"

  export MOCK_PCT_STATUS=running
  export MOCK_PCT_VERIFY_EXIT=0

  local out="${BATS_TEST_TMPDIR}/health.json"
  local result="${BATS_TEST_TMPDIR}/result.json"
  printf '{"version":"1.0","components":[]}\n' > "${result}"

  run emit_health_report "${out}" "wazuh" "${result}" "${BATS_TEST_TMPDIR}/no-mcp.json"
  assert_success
  jq -e '
    .kind == "health_report"
    and .overall_status == "healthy"
    and (.components | length == 1)
  ' "${out}"
}

@test "health_overall_status: running verify-fail component is unhealthy" {
  local comps arts
  comps='[{"observed_status":"unhealthy"}]'
  arts='[{"required":true,"status":"ok"}]'
  run health_overall_status "${comps}" "${arts}"
  assert_success
  assert_output "unhealthy"
}
