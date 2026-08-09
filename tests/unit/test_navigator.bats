#!/usr/bin/env bats
# ATT&CK Navigator coverage layer emitter

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_STACK_VERSION="1.0.0-test"
  mkdir -p "${SOC_STATE_DIR}/state"
  source_lib logging
  source "${REPO_ROOT}/scripts/lib/navigator.sh"
}

write_state() {
  local name="$1"
  local json="$2"
  printf '%s\n' "${json}" > "${SOC_STATE_DIR}/state/${name}.json"
}

@test "emit_navigator_layer writes valid Navigator v4.5 layer with empty techniques when no state" {
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  jq -e '.name' "${out}" >/dev/null
  jq -e '.domain == "enterprise-attack"' "${out}"
  jq -e '.versions.layer == "4.5"' "${out}"
  jq -e '.versions.navigator' "${out}" >/dev/null
  jq -e '.techniques | type == "array"' "${out}"
  jq -e '.techniques | length == 0' "${out}"
  [[ "$(stat -c "%a" "${out}")" == "600" ]]
}

@test "emit_navigator_layer includes techniques from a deployed component" {
  write_state wazuh '{"component":"wazuh","status":"deployed"}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  jq -e '.techniques | length > 0' "${out}"
  jq -e '[.techniques[].techniqueID] | index("T1059") != null' "${out}"
  jq -e '.techniques[] | select(.techniqueID=="T1059") | .score >= 1' "${out}"
  jq -e '.techniques[] | select(.techniqueID=="T1059") | .comment | test("Wazuh")' "${out}"
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("Wazuh")' "${out}"
}

@test "emit_navigator_layer skips components that are not deployed" {
  write_state wazuh '{"component":"wazuh","status":"failed"}'
  write_state misp '{"component":"misp","status":"deployed"}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  # MISP covers T1566; Wazuh also covers T1059 — T1059 must be absent
  jq -e '[.techniques[].techniqueID] | index("T1059") == null' "${out}"
  jq -e '[.techniques[].techniqueID] | index("T1566") != null' "${out}"
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("Wazuh") | not' "${out}"
}

@test "emit_navigator_layer includes integration techniques when integrated and peers deployed" {
  write_state wazuh '{"component":"wazuh","status":"deployed","integration":{"status":"integrated"},"integrations":[{"to":"thehive-cortex","type":"webhook","status":"configured"}]}'
  write_state thehive-cortex '{"component":"thehive-cortex","status":"deployed","integration":{"status":"integrated"}}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  # Integration adds T1486 comment about alert-to-case; score for shared tech > component alone
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("Wazuh -> TheHive webhook")' "${out}"
  jq -e '.techniques[] | select(.techniqueID=="T1486") | .score >= 2' "${out}"
}

@test "emit_navigator_layer excludes integration when integration.status is failed" {
  write_state wazuh '{"component":"wazuh","status":"deployed","integration":{"status":"failed"},"integrations":[{"to":"thehive-cortex","type":"webhook","status":"configured"}]}'
  write_state thehive-cortex '{"component":"thehive-cortex","status":"deployed","integration":{"status":"integrated"}}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("Wazuh -> TheHive webhook") | not' "${out}"
  # Component still contributes
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("Wazuh")' "${out}"
}

@test "emit_navigator_layer excludes integration when link record is not configured" {
  write_state wazuh '{"component":"wazuh","status":"deployed","integration":{"status":"integrated"},"integrations":[{"to":"thehive-cortex","type":"webhook","status":"failed"}]}'
  write_state thehive-cortex '{"component":"thehive-cortex","status":"deployed","integration":{"status":"integrated"}}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("Wazuh -> TheHive webhook") | not' "${out}"
}

@test "emit_navigator_layer excludes integration when peer component is not deployed" {
  write_state wazuh '{"component":"wazuh","status":"deployed","integration":{"status":"integrated"},"integrations":[{"to":"thehive-cortex","type":"webhook","status":"configured"}]}'
  write_state thehive-cortex '{"component":"thehive-cortex","status":"failed"}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("Wazuh -> TheHive webhook") | not' "${out}"
}

@test "emit_navigator_layer excludes unverified integrations (missing integration.status)" {
  write_state misp '{"component":"misp","status":"deployed"}'
  write_state zeek-suricata '{"component":"zeek-suricata","status":"deployed"}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  jq -e '.metadata[] | select(.name=="contributing_sources") | .value | test("MISP -> Suricata") | not' "${out}"
}

@test "emit_navigator_layer aggregates scores across multiple sources" {
  write_state wazuh '{"component":"wazuh","status":"deployed"}'
  write_state zeek-suricata '{"component":"zeek-suricata","status":"deployed"}'
  local out="${BATS_TEST_TMPDIR}/layer.json"
  emit_navigator_layer "${out}"
  # T1105 is covered by both wazuh and zeek-suricata
  jq -e '.techniques[] | select(.techniqueID=="T1105") | .score == 2' "${out}"
  jq -e '.gradient.maxValue >= 2' "${out}"
}

@test "emit_navigator_layer fails when coverage map is missing" {
  local out="${BATS_TEST_TMPDIR}/layer.json"
  run emit_navigator_layer "${out}" "${BATS_TEST_TMPDIR}/no-such-map.json"
  [[ "$status" -ne 0 ]]
}

@test "tools/export-navigator-layer.sh regenerates from state dir" {
  write_state misp '{"component":"misp","status":"deployed"}'
  local out="${BATS_TEST_TMPDIR}/exported.json"
  run "${REPO_ROOT}/tools/export-navigator-layer.sh" \
    --state-dir "${SOC_STATE_DIR}" \
    --out "${out}"
  assert_success
  jq -e '[.techniques[].techniqueID] | index("T1566") != null' "${out}"
}
