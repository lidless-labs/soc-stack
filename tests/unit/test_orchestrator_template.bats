#!/usr/bin/env bats
# Issue #7: template resolution must never continue with a nonexistent
# Ubuntu template after download failure.

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  local test_log_file="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_LOG_FILE="${test_log_file}"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
  OPT_LOG_FILE="${test_log_file}"
  source_libs
  export MOCK_PVEAM_CALLS_LOG="${BATS_TEST_TMPDIR}/pveam-calls.log"
  export MOCK_PVEAM_DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/pveam-downloads"
  : > "${MOCK_PVEAM_CALLS_LOG}"
}

stub_main_dependencies() {
  source_libs() { :; }
  check_root() { :; }
  check_proxmox_version() { :; }
  bootstrap_deps() { :; }
  check_deps() { :; }
  check_bridge() { :; }
  check_storage() { :; }
  plan_dependency_warnings() { :; }
  integrate_all() { :; }
  state_get() { printf ''; }
  mark_completed() { :; }
  emit_final_json() { :; }
  emit_mcp_config() { :; }
  emit_navigator_layer() { :; }
}

# No local template anywhere; pveam update succeeds; available list has the
# old archive missing but a newer supported Ubuntu 22.04 archive present.
setup_stale_repo() {
  export MOCK_PVEAM_LIST=""
  export MOCK_PVEAM_LIST_LOCAL=""
  export MOCK_PVEAM_AVAILABLE="system ubuntu-22.04-standard_22.04-2_amd64.tar.zst"
}

@test "ensure_ubuntu_template picks an available newer template when the historical archive is gone" {
  setup_stale_repo
  run ensure_ubuntu_template "local-lvm"
  assert_success
  assert_output --partial "ubuntu-22.04-standard_22.04-2_amd64.tar.zst"
  grep -q "pveam download local ubuntu-22.04-standard_22.04-2_amd64.tar.zst" \
    "${MOCK_PVEAM_CALLS_LOG}"
}

@test "ensure_ubuntu_template prefers ubuntu-22.04 when it is still available" {
  export MOCK_PVEAM_LIST=""
  export MOCK_PVEAM_LIST_LOCAL=""
  export MOCK_PVEAM_AVAILABLE="system ubuntu-24.04-standard_24.04-2_amd64.tar.zst
system ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  run ensure_ubuntu_template "local-lvm"
  assert_success
  assert_output --partial "ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
}

@test "ensure_ubuntu_template fails immediately when no supported Ubuntu template is available" {
  export MOCK_PVEAM_LIST=""
  export MOCK_PVEAM_LIST_LOCAL=""
  export MOCK_PVEAM_AVAILABLE="system ubuntu-24.04-standard_24.04-2_amd64.tar.zst
system debian-12-standard_12.2-1_amd64.tar.zst"
  run ensure_ubuntu_template "local-lvm"
  assert_failure
  assert_output --partial "no supported Ubuntu 22.04 standard template"
  # must not have attempted any download
  ! grep -q "download" "${MOCK_PVEAM_CALLS_LOG}"
}

@test "ensure_ubuntu_template fails and assigns nothing when download fails" {
  setup_stale_repo
  export MOCK_PVEAM_DOWNLOAD_EXIT=1
  run ensure_ubuntu_template "local-lvm"
  assert_failure
  assert_output --partial "pveam download local"
  refute_output --partial "local:vztmpl/ubuntu"
}

@test "ensure_ubuntu_template verifies the downloaded volume exists before returning it" {
  # download reports success but the volume is not in `pveam list local`
  export MOCK_PVEAM_LIST=""
  export MOCK_PVEAM_LIST_LOCAL=""
  export MOCK_PVEAM_AVAILABLE="system ubuntu-22.04-standard_22.04-2_amd64.tar.zst"
  unset MOCK_PVEAM_DOWNLOAD_DIR
  run ensure_ubuntu_template "local-lvm"
  assert_failure
  assert_output --partial "missing after download"
}

@test "ensure_ubuntu_template does not download when a suitable template exists locally" {
  export MOCK_PVEAM_LIST="local-lvm:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  run ensure_ubuntu_template "local-lvm"
  assert_success
  assert_output --partial "local-lvm:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  ! grep -q "download" "${MOCK_PVEAM_CALLS_LOG}"
}

@test "ensure_ubuntu_template rejects unsupported local Ubuntu releases" {
  export MOCK_PVEAM_LIST="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  export MOCK_PVEAM_LIST_LOCAL=""
  export MOCK_PVEAM_AVAILABLE="system ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  run ensure_ubuntu_template "local-lvm"
  assert_failure
  assert_output --partial "no supported Ubuntu 22.04 standard template"
  ! grep -q "download" "${MOCK_PVEAM_CALLS_LOG}"
}

@test "ensure_ubuntu_template fails when pveam update fails" {
  export MOCK_PVEAM_LIST=""
  export MOCK_PVEAM_LIST_LOCAL=""
  export MOCK_PVEAM_UPDATE_EXIT=1
  run ensure_ubuntu_template "local-lvm"
  assert_failure
  assert_output --partial "pveam update"
  ! grep -q "download" "${MOCK_PVEAM_CALLS_LOG}"
}

@test "main fails template preflight before deploying or writing failure state" {
  stub_main_dependencies
  local calls="${BATS_TEST_TMPDIR}/orchestrator-calls.log"
  ensure_ubuntu_template() { printf 'ensure\n' >> "${calls}"; return 1; }
  deploy_one() { printf 'deploy\n' >> "${calls}"; return 0; }
  state_set() { printf 'state-set\n' >> "${calls}"; }
  pct() { printf 'pct\n' >> "${calls}"; return 0; }

  run main --components wazuh --storage local-lvm \
    --state-dir "${SOC_STATE_DIR}" --log-file "${SOC_LOG_FILE}" \
    --json-out "${BATS_TEST_TMPDIR}/result.json" \
    --mcp-config-out "${BATS_TEST_TMPDIR}/mcp.json" \
    --navigator-out "${BATS_TEST_TMPDIR}/navigator.json"

  assert_failure 1
  assert_output --partial "aborting before deployment"
  [[ "$(grep -c '^ensure$' "${calls}")" -eq 1 ]]
  ! grep -qE '^(deploy|state-set|pct)$' "${calls}"
}

@test "main skips template preflight when every selected component is complete" {
  stub_main_dependencies
  local calls="${BATS_TEST_TMPDIR}/completed-calls.log"
  is_completed() { return 0; }
  ensure_ubuntu_template() { printf 'ensure\n' >> "${calls}"; return 1; }
  pct() { printf 'pct\n' >> "${calls}"; return 0; }

  run main --components wazuh --storage local-lvm \
    --state-dir "${SOC_STATE_DIR}" --log-file "${SOC_LOG_FILE}" \
    --json-out "${BATS_TEST_TMPDIR}/result.json" \
    --mcp-config-out "${BATS_TEST_TMPDIR}/mcp.json" \
    --navigator-out "${BATS_TEST_TMPDIR}/navigator.json"

  assert_success
  assert_output --partial "already deployed"
  [[ ! -e "${calls}" ]]
}

@test "post-download verification tolerates a large template listing" {
  setup_stale_repo
  export MOCK_PVEAM_POST_DOWNLOAD_TAIL_LINES=20000

  run ensure_ubuntu_template "local-lvm"

  assert_success
  assert_output --partial "local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst"
}
