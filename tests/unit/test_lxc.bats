#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib lxc
}

@test "lxc_exists returns success when pct status reports running" {
  export MOCK_PCT_STATUS=running
  run lxc_exists 9001
  assert_success
}

@test "lxc_exists returns failure when pct exits non-zero" {
  export MOCK_PCT_EXIT=2
  run lxc_exists 9001
  [[ "$status" -ne 0 ]]
}

@test "lxc_running returns success only when pct status says running" {
  export MOCK_PCT_STATUS=running
  run lxc_running 9001
  assert_success
}

@test "lxc_running returns failure when stopped" {
  export MOCK_PCT_STATUS=stopped
  run lxc_running 9001
  [[ "$status" -ne 0 ]]
}

@test "lxc_create invokes pct create with expected args" {
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  MOCK_PCT_EXIT=1
  export MOCK_PCT_CALLS_LOG MOCK_PCT_EXIT
  lxc_create 9001 \
    "s3-test" \
    "local:vztmpl/ubuntu-22.04.tar.zst" \
    --memory 2048 \
    --cores 1 \
    --rootfs "local-lvm:30" \
    --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
    --password "p4ss" || true
  grep -q "pct create 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_start is idempotent when already running" {
  MOCK_PCT_STATUS=running
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_start 9001
  ! grep -q "pct start 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_start invokes pct start when stopped" {
  MOCK_PCT_STATUS=stopped
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_start 9001
  grep -q "pct start 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_wait_network returns success when pct exec ping succeeds on first attempt" {
  MOCK_PCT_EXIT=0 run lxc_wait_network 9001 10
  assert_success
}

@test "lxc_wait_network honors a custom timeout" {
  # Force ping to always fail by making pct exec exit non-zero
  export MOCK_PCT_EXIT=1
  local start
  start=$(date +%s)
  run lxc_wait_network 9001 4
  local elapsed=$(( $(date +%s) - start ))
  [[ "$status" -ne 0 ]]
  # Should have given up by ~4-6s, not waited the full default
  (( elapsed <= 8 ))
}
