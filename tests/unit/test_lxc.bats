#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

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
  if grep -q "pct start 9001" "${MOCK_PCT_CALLS_LOG}"; then
    return 1
  fi
}

@test "lxc_start invokes pct start when stopped" {
  MOCK_PCT_STATUS=stopped
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_start 9001
  grep -q "pct start 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_stop is a no-op when already stopped" {
  MOCK_PCT_STATUS=stopped
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_stop 9001
  run grep -q "pct stop 9001" "${MOCK_PCT_CALLS_LOG}"
  assert_failure
}

@test "lxc_stop invokes pct stop when running" {
  MOCK_PCT_STATUS=running
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_stop 9001
  grep -q "pct stop 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_destroy is a no-op when the LXC does not exist" {
  MOCK_PCT_EXIT=2   # pct status fails -> lxc_exists false
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_EXIT MOCK_PCT_CALLS_LOG
  run lxc_destroy 9001
  assert_success
  run grep -q "pct destroy" "${MOCK_PCT_CALLS_LOG}"
  assert_failure
}

@test "lxc_destroy stops then destroys a running LXC" {
  MOCK_PCT_STATUS=running
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_destroy 9001
  grep -q "pct stop 9001" "${MOCK_PCT_CALLS_LOG}"
  grep -q "pct destroy 9001" "${MOCK_PCT_CALLS_LOG}"
}

@test "lxc_destroy destroys a stopped-but-existing LXC without stopping it" {
  MOCK_PCT_STATUS=stopped   # pct status exits 0 (exists) but not running
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_STATUS MOCK_PCT_CALLS_LOG
  lxc_destroy 9001
  run grep -q "pct stop 9001" "${MOCK_PCT_CALLS_LOG}"
  assert_failure
  run grep -q "pct destroy 9001" "${MOCK_PCT_CALLS_LOG}"
  assert_success
}

@test "lxc_push_script pushes the file and makes it executable" {
  MOCK_PCT_CALLS_LOG="${BATS_TEST_TMPDIR}/pct-calls.log"
  export MOCK_PCT_CALLS_LOG
  lxc_push_script 9001 /tmp/local.sh /tmp/remote.sh
  grep -q "pct push 9001 /tmp/local.sh /tmp/remote.sh" "${MOCK_PCT_CALLS_LOG}"
  grep -q "pct exec 9001 -- chmod +x /tmp/remote.sh" "${MOCK_PCT_CALLS_LOG}"
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
