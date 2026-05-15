#!/usr/bin/env bats

load helpers/load.bash

@test "bats helper is loaded and SOC_STATE_DIR is set" {
  [[ -n "${SOC_STATE_DIR:-}" ]]
  [[ -d "${SOC_STATE_DIR}" ]]
}

@test "fake pct is on PATH and records calls" {
  pct status 9999
  [[ -f "${BATS_TEST_TMPDIR}/pct-calls.log" ]]
  grep -q "pct status 9999" "${BATS_TEST_TMPDIR}/pct-calls.log"
}

@test "fake docker is on PATH and records calls" {
  docker ps
  [[ -f "${BATS_TEST_TMPDIR}/docker-calls.log" ]]
  grep -q "docker ps" "${BATS_TEST_TMPDIR}/docker-calls.log"
}

@test "MOCK_PCT_STATUS=running flips the mock output" {
  export MOCK_PCT_STATUS=running
  run pct status 9999
  assert_success
  assert_output --partial "running"
}
