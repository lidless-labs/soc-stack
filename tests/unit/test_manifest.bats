#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib manifest
}

@test "parse_manifest extracts components array" {
  run parse_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json" "components"
  assert_success
  assert_output --partial "wazuh"
}

@test "parse_manifest extracts nested keys" {
  run parse_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json" "network.bridge"
  assert_success
  assert_output "vmbr0"
}

@test "validate_manifest accepts valid manifest" {
  run validate_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json"
  assert_success
}

@test "validate_manifest rejects missing components" {
  run validate_manifest "${REPO_ROOT}/tests/unit/fixtures/manifests/missing-components.json"
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"components"* ]]
}

@test "merge_flags_into_manifest applies flag overrides" {
  local out="${BATS_TEST_TMPDIR}/merged.json"
  merge_flags_into_manifest \
    "${REPO_ROOT}/tests/unit/fixtures/manifests/valid.json" \
    --preset minimal \
    --bridge vmbr1 \
    > "${out}"
  jq -e '.preset == "minimal"' "${out}"
  jq -e '.network.bridge == "vmbr1"' "${out}"
}

@test "build_manifest_from_flags produces valid manifest" {
  local out="${BATS_TEST_TMPDIR}/from-flags.json"
  build_manifest_from_flags \
    --components wazuh \
    --preset standard \
    --bridge vmbr0 \
    --storage local-lvm \
    --ip-mode dhcp \
    > "${out}"
  jq -e '.components[0] == "wazuh"' "${out}"
  jq -e '.preset == "standard"' "${out}"
}
