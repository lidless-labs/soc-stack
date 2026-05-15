#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  source_lib logging
  source_lib network
  source_lib preflight
}

@test "check_root returns success when EUID=0 (simulated)" {
  _SOC_EUID=0 run check_root
  assert_success
}

@test "check_root fails when not root" {
  _SOC_EUID=1000 run check_root
  [[ "$status" -ne 0 ]]
}

@test "check_storage validates storage exists in pvesm output" {
  run check_storage "local-lvm"
  assert_success
}

@test "check_storage fails on unknown storage" {
  export MOCK_PVESM_STATUS=$'Name Type Status Total Used Available %\nlocal dir active 100GB 10GB 90GB 10%'
  run check_storage "missing-pool"
  [[ "$status" -ne 0 ]]
}

@test "check_proxmox_version accepts 7.x" {
  cat > "${BATS_TEST_TMPDIR}/pveversion" <<'EOF'
#!/usr/bin/env bash
echo "pve-manager/7.4-17/513c62be"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/pveversion"
  PATH="${BATS_TEST_TMPDIR}:${PATH}" run check_proxmox_version
  assert_success
}

@test "check_proxmox_version accepts 8.x" {
  cat > "${BATS_TEST_TMPDIR}/pveversion" <<'EOF'
#!/usr/bin/env bash
echo "pve-manager/8.2.4/abc123"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/pveversion"
  PATH="${BATS_TEST_TMPDIR}:${PATH}" run check_proxmox_version
  assert_success
}

@test "check_proxmox_version rejects 6.x" {
  cat > "${BATS_TEST_TMPDIR}/pveversion" <<'EOF'
#!/usr/bin/env bash
echo "pve-manager/6.4-15/abc123"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/pveversion"
  PATH="${BATS_TEST_TMPDIR}:${PATH}" run check_proxmox_version
  [[ "$status" -ne 0 ]]
}
