#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
}

@test "expand_components 'all' returns the canonical 6" {
  run expand_components "all"
  assert_success
  [[ "${output}" == *"wazuh"* ]]
  [[ "${output}" == *"thehive-cortex"* ]]
  [[ "${output}" == *"misp"* ]]
  [[ "${output}" == *"zeek-suricata"* ]]
  [[ "${output}" == *"dashboards"* ]]
  [[ "${output}" == *"mcp"* ]]
}

@test "expand_components CSV preserves order" {
  run expand_components "misp,wazuh"
  assert_success
  assert_output "misp wazuh"
}

@test "build_manifest produces JSON matching flags" {
  parse_args --components wazuh --preset minimal --bridge vmbr-test --vmid-start 9000
  local out
  out="$(build_manifest)"
  jq -e '.components[0] == "wazuh"' <<< "${out}"
  jq -e '.preset == "minimal"' <<< "${out}"
  jq -e '.network.bridge == "vmbr-test"' <<< "${out}"
  jq -e '.vmid_start == 9000' <<< "${out}"
}

@test "build_manifest rejects unknown component" {
  parse_args --components imaginary-component
  run build_manifest
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"unknown"* ]]
}

@test "build_manifest rejects duplicate components" {
  parse_args --components wazuh,wazuh
  run build_manifest
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"duplicate"* ]]
}

@test "build_manifest rejects empty component list" {
  parse_args --components ""
  run build_manifest
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"component"* ]]
}

@test "deploy_one allocates static IPs by component index in dry-run" {
  parse_args \
    --components wazuh,misp \
    --ip-mode static \
    --ip-range 198.51.100.10/24 \
    --dry-run \
    --state-dir "${SOC_STATE_DIR}" \
    --log-file "${SOC_LOG_FILE}"
  source_libs
  local manifest
  manifest="$(build_manifest)"

  deploy_one misp "${manifest}" 1

  grep -q "ip=198.51.100.11/24" "${SOC_LOG_FILE}"
}

@test "dependency warnings are recorded for selected-only degraded mode" {
  parse_args --components mcp --state-dir "${SOC_STATE_DIR}" --log-file "${SOC_LOG_FILE}"
  source_libs

  plan_dependency_warnings mcp

  [[ "${#SOC_WARNINGS[@]}" -ge 4 ]]
  [[ "$(warnings_json)" == *"mcp selected without wazuh"* ]]
}
