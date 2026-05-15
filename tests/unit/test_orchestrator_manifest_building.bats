#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
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
