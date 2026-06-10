#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib network
}

@test "next_vmid returns sequential starting from vmid_start" {
  MOCK_PCT_LIST=$'VMID Status Lock Name\n100 running - existing1\n101 running - existing2'
  export MOCK_PCT_LIST
  MOCK_QM_LIST=$'VMID NAME STATUS\n102 vm-a stopped'
  export MOCK_QM_LIST

  run next_vmid 100
  assert_success
  assert_output "103"
}

@test "next_vmid skips occupied IDs" {
  MOCK_PCT_LIST=$'VMID Status Lock Name\n200 running - a\n201 running - b\n203 running - c'
  export MOCK_PCT_LIST
  MOCK_QM_LIST=$'VMID NAME STATUS'
  export MOCK_QM_LIST

  run next_vmid 200
  assert_success
  assert_output "202"
}

@test "next_vmid honors a higher starting VMID" {
  MOCK_PCT_LIST=$'VMID Status Lock Name'
  export MOCK_PCT_LIST
  MOCK_QM_LIST=$'VMID NAME STATUS'
  export MOCK_QM_LIST

  run next_vmid 9000
  assert_success
  assert_output "9000"
}

@test "allocate_ip with /24 returns sequential addresses" {
  run allocate_ip "198.51.100.10/24" 0
  assert_output "198.51.100.10/24"
  run allocate_ip "198.51.100.10/24" 1
  assert_output "198.51.100.11/24"
  run allocate_ip "198.51.100.10/24" 5
  assert_output "198.51.100.15/24"
}

@test "allocate_ip allows the last valid host octet (254)" {
  run allocate_ip "198.51.100.250/24" 4
  assert_success
  assert_output "198.51.100.254/24"
}

@test "allocate_ip fails when the last octet would overflow host range" {
  run allocate_ip "198.51.100.250/24" 5
  assert_failure
  run allocate_ip "198.51.100.10/24" 250
  assert_failure
}

@test "validate_bridge accepts existing bridge" {
  MOCK_IP_LINK_SHOW="vmbr0: <BROADCAST,MULTICAST,UP,LOWER_UP>"
  MOCK_IP_LINK_EXIT="0"
  export MOCK_IP_LINK_SHOW MOCK_IP_LINK_EXIT
  run validate_bridge "vmbr0"
  assert_success
}
