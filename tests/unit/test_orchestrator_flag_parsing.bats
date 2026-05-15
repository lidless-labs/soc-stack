#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  # Source the orchestrator with a guard so it does not run main()
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
}

@test "parse_args sets defaults" {
  parse_args
  [[ "${OPT_COMPONENTS}" == "all" ]]
  [[ "${OPT_PRESET}" == "standard" ]]
  [[ "${OPT_BRIDGE}" == "vmbr0" ]]
  [[ "${OPT_IP_MODE}" == "dhcp" ]]
  [[ "${OPT_STATE_DIR}" == "/var/lib/soc-stack" ]]
  [[ "${OPT_JSON_OUT}" == "/root/soc-stack.json" ]]
}

@test "parse_args overrides via --components" {
  parse_args --components wazuh,misp
  [[ "${OPT_COMPONENTS}" == "wazuh,misp" ]]
}

@test "parse_args overrides --preset minimal" {
  parse_args --preset minimal
  [[ "${OPT_PRESET}" == "minimal" ]]
}

@test "parse_args overrides --bridge --storage" {
  parse_args --bridge vmbr1 --storage local-lvm-test
  [[ "${OPT_BRIDGE}" == "vmbr1" ]]
  [[ "${OPT_STORAGE}" == "local-lvm-test" ]]
}

@test "parse_args sets OPT_DRY_RUN=1 when --dry-run is passed" {
  parse_args --dry-run
  [[ "${OPT_DRY_RUN}" == "1" ]]
}

@test "parse_args sets OPT_FORCE=1 when --force is passed" {
  parse_args --force
  [[ "${OPT_FORCE}" == "1" ]]
}

@test "parse_args sets OPT_VMID_START" {
  parse_args --vmid-start 9000
  [[ "${OPT_VMID_START}" == "9000" ]]
}

@test "parse_args exits with --version" {
  run parse_args --version
  assert_success
  assert_output --partial "soc-stack"
}

@test "parse_args fails on unknown flag" {
  run parse_args --not-a-flag
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"unknown"* ]]
}
