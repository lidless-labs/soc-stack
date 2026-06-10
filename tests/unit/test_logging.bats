#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "$(dirname "${SOC_LOG_FILE}")"
  source_lib logging
}

@test "msg_info prints to stderr with INFO marker" {
  run --separate-stderr msg_info "starting up"
  assert_success
  assert [ -z "${output:-}" ]
  # shellcheck disable=SC2154
  [[ "${stderr}" == *"starting up"* ]]
}

@test "msg_info writes to log file with ISO timestamp and INFO level" {
  msg_info "test message"
  grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}.*\] INFO  test message$' "${SOC_LOG_FILE}"
}

@test "msg_ok writes OK level to log" {
  msg_ok "completed"
  grep "OK    completed" "${SOC_LOG_FILE}"
}

@test "msg_error writes ERROR level to log and stderr" {
  run --separate-stderr msg_error "boom"
  # shellcheck disable=SC2154
  [[ "${stderr}" == *"boom"* ]]
  grep "ERROR boom" "${SOC_LOG_FILE}"
}

@test "msg_warn writes WARN level to log" {
  msg_warn "be careful"
  grep "WARN  be careful" "${SOC_LOG_FILE}"
}

@test "log file is created if directory exists" {
  rm -f "${SOC_LOG_FILE}"
  msg_info "first message"
  [[ -f "${SOC_LOG_FILE}" ]]
}
