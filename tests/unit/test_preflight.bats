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

@test "bootstrap_deps no-ops when all deps present" {
  # `jq curl wget openssl` are all present on the dev machine
  MOCK_APTGET_CALLS_LOG="${BATS_TEST_TMPDIR}/apt-get-calls.log"
  export MOCK_APTGET_CALLS_LOG
  run bootstrap_deps
  assert_success
  [[ ! -s "${MOCK_APTGET_CALLS_LOG}" ]]  # no apt-get calls recorded
}

@test "bootstrap_deps invokes apt-get install when a dep is missing" {
  # Build a controlled PATH: system utils we need + our mocks, but NO jq.
  # We symlink essential binaries so logging (date, dirname) still works,
  # then provide apt-get mock + curl/wget/openssl stubs, and omit jq.
  local fakebin="${BATS_TEST_TMPDIR}/fakebin"
  mkdir -p "${fakebin}"

  # Symlink essential system utilities (logging.sh, shell scripting, shebang runner)
  for t in date dirname basename mkdir cat grep awk head tee tput env bash sh; do
    local tpath; tpath="$(command -v "${t}" 2>/dev/null)" || true
    [[ -n "${tpath}" ]] && ln -sf "${tpath}" "${fakebin}/${t}"
  done

  # Place our mock apt-get (records calls to MOCK_APTGET_CALLS_LOG)
  cp "${REPO_ROOT}/tests/unit/fixtures/bin/apt-get" "${fakebin}/"

  # Provide curl/wget/openssl stubs but deliberately omit jq
  for t in curl wget openssl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${fakebin}/${t}"
    chmod +x "${fakebin}/${t}"
  done

  MOCK_APTGET_CALLS_LOG="${BATS_TEST_TMPDIR}/apt-get-calls.log"
  export MOCK_APTGET_CALLS_LOG

  # Use only fakebin on PATH so jq is not found, triggering bootstrap
  PATH="${fakebin}" run bootstrap_deps
  assert_success
  grep -q "apt-get install" "${MOCK_APTGET_CALLS_LOG}"
  grep -q "jq" "${MOCK_APTGET_CALLS_LOG}"
}
