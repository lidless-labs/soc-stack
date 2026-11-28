#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
  OPT_STATE_DIR="${SOC_STATE_DIR}"
  OPT_LOG_FILE="${SOC_LOG_FILE}"
  source_libs
  # Keep the real state and output functions, but replace host preflight checks.
  source_libs() { :; }
  check_root() { :; }
  check_proxmox_version() { :; }
  bootstrap_deps() { :; }
  check_deps() { :; }
  check_bridge() { :; }
  check_storage() { :; }
  next_vmid() { echo 7000; }
  COMPONENTS_KNOWN=(example another)
  COMPONENTS_DIR="${BATS_TEST_TMPDIR}/components"
  local component
  for component in "${COMPONENTS_KNOWN[@]}"; do
    mkdir -p "${COMPONENTS_DIR}/${component}"
    printf '#!/usr/bin/env bash\ntouch "%s"\n' "${BATS_TEST_TMPDIR}/${component}-spec-called" > "${COMPONENTS_DIR}/${component}/lxc-spec.sh"
    chmod +x "${COMPONENTS_DIR}/${component}/lxc-spec.sh"
  done
  export TEMPLATE_CALLS="${BATS_TEST_TMPDIR}/calls"
  export TEMPLATE_VOLUME="${BATS_TEST_TMPDIR}/volume"
  AVAILABLE=$'system ubuntu-24.04-standard_24.04-2_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-2_amd64.tar.zst'
  UPDATE_RC=0
  UPDATE_STDERR=""
  UPDATE_STDOUT=""
  AVAILABLE_RC=0
  DOWNLOAD_RC=0
  MISSING_VOLUME=0
  VERIFY_LIST_RC=0
  SELECTED=example
  STORAGE=local-lvm
  pveam() {
    echo "$*" >> "${TEMPLATE_CALLS}"
    case "$1" in
      list)
        [[ "$2" != local-lvm ]] || return 255
        if [[ "$2" == "${STORAGE}" && "${STORAGE}" != local ]]; then
          printf '%s\n' "${STORAGE_VOLUMES:-}"
        elif [[ "$2" == local && -f "${TEMPLATE_VOLUME}" ]]; then
          cat "${TEMPLATE_VOLUME}"
          return "${VERIFY_LIST_RC}"
        fi
        return 0
        ;;
      update) printf '%s' "${UPDATE_STDOUT}"; printf '%s' "${UPDATE_STDERR}" >&2; return "${UPDATE_RC}" ;;
      available) printf '%s\n' "${AVAILABLE}"; return "${AVAILABLE_RC}" ;;
      download)
        [[ "$2" == local ]] || return 1
        [[ "${DOWNLOAD_RC}" == 0 ]] || return "${DOWNLOAD_RC}"
        if [[ "${MISSING_VOLUME}" == 0 ]]; then
          echo "local:vztmpl/$3 100MB" > "${TEMPLATE_VOLUME}"
        fi
        ;;
      *) return 1 ;;
    esac
  }
}

run_plan() {
  main --components "${SELECTED}" --storage "${STORAGE}" --preset minimal \
    --vmid-start 7000 --dry-run --non-interactive --no-integrate \
    --state-dir "${SOC_STATE_DIR}" --log-file "${SOC_LOG_FILE}" \
    --json-out "${BATS_TEST_TMPDIR}/result.json" \
    --mcp-config-out "${BATS_TEST_TMPDIR}/mcp.json" --navigator-out "" "$@"
}

assert_failed_plan() {
  assert_failure 3
  jq -e '.components | length == 1 and .[0].name == "example" and .[0].status == "failed"' "${BATS_TEST_TMPDIR}/result.json"
  [[ ! -e "${BATS_TEST_TMPDIR}/example-spec-called" ]]
}

@test "template uses an available Ubuntu 22.04 archive and runs the component spec" {
  run run_plan
  assert_success
  assert_output --partial 'local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst'
  [[ -f "${BATS_TEST_TMPDIR}/example-spec-called" ]]
  [[ "$(cat "${TEMPLATE_CALLS}")" == $'list local-lvm\nlist local\nupdate\navailable\ndownload local ubuntu-22.04-standard_22.04-2_amd64.tar.zst\nlist local' ]]
}

@test "template listing tolerates status 255 under errexit outside the deploy conditional" {
  export AVAILABLE UPDATE_RC UPDATE_STDERR UPDATE_STDOUT AVAILABLE_RC DOWNLOAD_RC MISSING_VOLUME VERIFY_LIST_RC STORAGE
  export -f pveam resolve_template newest_template msg_info msg_error _soc_log
  run bash -euo pipefail -c 'resolve_template local-lvm'
  assert_success
  assert_output --partial 'local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst'
}

@test "template reuses an installed Ubuntu 22.04 volume without downloading" {
  echo 'local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst 100MB' > "${TEMPLATE_VOLUME}"
  run run_plan
  assert_success
  [[ "$(cat "${TEMPLATE_CALLS}")" == $'list local-lvm\nlist local' ]]
  [[ -f "${BATS_TEST_TMPDIR}/example-spec-called" ]]
}

@test "template reuses a volume on the requested non-local storage" {
  STORAGE=templates
  STORAGE_VOLUMES='templates:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.xz 100MB'
  run run_plan
  assert_success
  assert_output --partial 'templates:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.xz'
  [[ "$(cat "${TEMPLATE_CALLS}")" == 'list templates' ]]
  [[ -f "${BATS_TEST_TMPDIR}/example-spec-called" ]]
}

@test "template selects the newest catalog version with zst preferred only on a tie" {
  AVAILABLE=$'system ubuntu-22.04-standard_22.04-2_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-10_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-10_amd64.tar.xz\nsystem ubuntu-22.04-standard_22.04-10_amd64.tar.gz\nsystem ubuntu-22.04-standard_22.04-9_amd64.tar.zst\nsystem ubuntu-24.04-standard_24.04-20_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-20_arm64.tar.zst'
  run run_plan
  assert_success
  [[ "$(cat "${TEMPLATE_VOLUME}")" == 'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.zst 100MB' ]]
}

@test "template selects a newer catalog version over an older zst archive" {
  AVAILABLE=$'system ubuntu-22.04-standard_22.04-2_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-10_amd64.tar.gz'
  run run_plan
  assert_success
  assert_output --partial 'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.gz'
}

@test "template selects the newest installed version and prefers zst on a tie" {
  printf '%s\n' \
    'local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst 100MB' \
    'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.zst 100MB' \
    'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.xz 100MB' \
    'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.gz 100MB' \
    'local:vztmpl/ubuntu-22.04-standard_22.04-9_amd64.tar.zst 100MB' > "${TEMPLATE_VOLUME}"
  run run_plan
  assert_success
  assert_output --partial 'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.zst'
  [[ "$(cat "${TEMPLATE_CALLS}")" == $'list local-lvm\nlist local' ]]
}

@test "template selects a newer installed version over an older zst archive" {
  printf '%s\n' \
    'local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst 100MB' \
    'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.xz 100MB' > "${TEMPLATE_VOLUME}"
  run run_plan
  assert_success
  assert_output --partial 'local:vztmpl/ubuntu-22.04-standard_22.04-10_amd64.tar.xz'
}

@test "template stops before deployment when index refresh reports failure on stderr with exit zero" {
  UPDATE_STDERR='update failed - mirror unavailable'
  run run_plan
  assert_failed_plan
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == update ]]
}

@test "template keeps ordinary hard-error handling for index refresh" {
  UPDATE_RC=1
  UPDATE_STDERR='catalog refresh error'
  run run_plan
  assert_failed_plan
  assert_output --partial 'catalog refresh error'
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == update ]]
}

@test "template permits harmless refresh stderr" {
  UPDATE_STDERR='catalog refresh notice'
  run run_plan
  assert_success
  [[ -f "${BATS_TEST_TMPDIR}/example-spec-called" ]]
}

@test "template keeps refresh stdout out of the resolved volume and checks only stderr for failure" {
  UPDATE_STDOUT='update failed counter: 0'
  run run_plan
  assert_success
  assert_output --partial 'pct create 7000 local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst'
  [[ -f "${BATS_TEST_TMPDIR}/example-spec-called" ]]
}

@test "template stops before deployment when available query fails" {
  AVAILABLE_RC=1
  run run_plan
  assert_failed_plan
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == available ]]
}

@test "template fails when no supported archive is available" {
  AVAILABLE=$'system ubuntu-24.04-standard_24.04-2_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-2_arm64.tar.zst'
  run run_plan
  assert_failed_plan
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == available ]]
}

@test "template fails immediately when download fails" {
  DOWNLOAD_RC=1
  run run_plan
  assert_failed_plan
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == 'download local ubuntu-22.04-standard_22.04-2_amd64.tar.zst' ]]
}

@test "template fails when a successful download leaves the selected volume absent" {
  MISSING_VOLUME=1
  run run_plan
  assert_failed_plan
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == 'list local' ]]
}

@test "template fails when the downloaded volume cannot be listed" {
  VERIFY_LIST_RC=255
  run run_plan
  assert_failed_plan
}

@test "template resolves once before all component specs on success" {
  SELECTED=example,another
  run run_plan
  assert_success
  [[ "$(grep -c '^update$' "${TEMPLATE_CALLS}")" == 1 ]]
  [[ "$(grep -c '^list local-lvm$' "${TEMPLATE_CALLS}")" == 1 ]]
  [[ -f "${BATS_TEST_TMPDIR}/example-spec-called" && -f "${BATS_TEST_TMPDIR}/another-spec-called" ]]
}

@test "template failure resolves once and records all affected components in result JSON" {
  SELECTED=example,another
  UPDATE_STDERR='update failed'
  run run_plan
  assert_failure 3
  [[ "$(cat "${TEMPLATE_CALLS}")" == $'list local-lvm\nlist local\nupdate' ]]
  jq -e '.components | length == 2 and all(.[]; .status == "failed")' "${BATS_TEST_TMPDIR}/result.json"
  [[ ! -e "${BATS_TEST_TMPDIR}/example-spec-called" && ! -e "${BATS_TEST_TMPDIR}/another-spec-called" ]]
}

@test "template failure preserves completed components and reports mixed state on resume" {
  SELECTED=example,another
  state_set example status deployed
  UPDATE_STDERR='update failed'
  run run_plan
  assert_failure 5
  jq -e '.components | any(.[]; .name == "example" and .status == "deployed") and any(.[]; .name == "another" and .status == "failed")' "${BATS_TEST_TMPDIR}/result.json"
  [[ ! -e "${BATS_TEST_TMPDIR}/example-spec-called" && ! -e "${BATS_TEST_TMPDIR}/another-spec-called" ]]
}

@test "template resolution is a no-op when all requested components are complete" {
  state_set example status deployed
  UPDATE_STDERR='update failed'
  run run_plan
  assert_success
  [[ ! -e "${TEMPLATE_CALLS}" && ! -e "${BATS_TEST_TMPDIR}/example-spec-called" ]]
  [[ "$(state_get example status)" == deployed ]]
}

@test "template resolution runs for completed components under force" {
  state_set example status deployed
  UPDATE_STDERR='update failed'
  run run_plan --force
  assert_failed_plan
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == update ]]
}
