#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
  OPT_LOG_FILE="${SOC_LOG_FILE}"
  source_libs
  OPT_DRY_RUN=1
  COMPONENTS_DIR="${BATS_TEST_TMPDIR}/components"
  mkdir -p "${COMPONENTS_DIR}/example"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "${BATS_TEST_TMPDIR}/spec-called" > "${COMPONENTS_DIR}/example/lxc-spec.sh"
  chmod +x "${COMPONENTS_DIR}/example/lxc-spec.sh"
  export TEMPLATE_CALLS="${BATS_TEST_TMPDIR}/calls"
  export TEMPLATE_VOLUME="${BATS_TEST_TMPDIR}/volume"
  AVAILABLE=$'system ubuntu-24.04-standard_24.04-2_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-2_amd64.tar.zst'
  UPDATE_RC=0
  AVAILABLE_RC=0
  DOWNLOAD_RC=0
  MISSING_VOLUME=0
  MANIFEST='{"preset":"minimal","network":{"bridge":"vmbr0","storage":"local-lvm","ip_mode":"dhcp"},"vmid_start":7000}'
  next_vmid() { echo 7000; }
  pveam() {
    echo "$*" >> "${TEMPLATE_CALLS}"
    case "$1" in
      list) [[ "$2" == local && -f "${TEMPLATE_VOLUME}" ]] && cat "${TEMPLATE_VOLUME}"; return 0 ;;
      update) return "${UPDATE_RC}" ;;
      available) printf '%s\n' "${AVAILABLE}"; return "${AVAILABLE_RC}" ;;
      download)
        [[ "$3" == ubuntu-22.04-standard_22.04-2_amd64.tar.zst ]] || return 1
        [[ "${DOWNLOAD_RC}" == 0 ]] || return "${DOWNLOAD_RC}"
        if [[ "${MISSING_VOLUME}" == 0 ]]; then
          echo "local:vztmpl/$3 100MB" > "${TEMPLATE_VOLUME}"
        fi
        ;;
      *) return 1 ;;
    esac
  }
}

@test "template uses an available Ubuntu 22.04 archive when the historical archive is absent" {
  run deploy_one example "${MANIFEST}" 0
  assert_success
  assert_output --partial 'local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst'
  [[ "$(cat "${TEMPLATE_CALLS}")" == $'list local-lvm\nlist local\nupdate\navailable\ndownload local ubuntu-22.04-standard_22.04-2_amd64.tar.zst\nlist local' ]]
}

@test "template reuses an installed Ubuntu 22.04 volume without downloading" {
  echo 'local:vztmpl/ubuntu-22.04-standard_22.04-2_amd64.tar.zst 100MB' > "${TEMPLATE_VOLUME}"
  run deploy_one example "${MANIFEST}" 0
  assert_success
  [[ "$(cat "${TEMPLATE_CALLS}")" == $'list local-lvm\nlist local' ]]
}

@test "template stops before deployment when index refresh fails" {
  UPDATE_RC=1
  run deploy_one example "${MANIFEST}" 0
  assert_failure
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == update ]]
  [[ ! -e "${BATS_TEST_TMPDIR}/spec-called" ]]
}

@test "template stops before deployment when available query fails" {
  AVAILABLE_RC=1
  run deploy_one example "${MANIFEST}" 0
  assert_failure
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == available ]]
  [[ ! -e "${BATS_TEST_TMPDIR}/spec-called" ]]
}

@test "template fails when no supported archive is available" {
  AVAILABLE=$'system ubuntu-24.04-standard_24.04-2_amd64.tar.zst\nsystem ubuntu-22.04-standard_22.04-2_arm64.tar.zst'
  run deploy_one example "${MANIFEST}" 0
  assert_failure
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == available ]]
  [[ ! -e "${BATS_TEST_TMPDIR}/spec-called" ]]
}

@test "template fails immediately when download fails" {
  DOWNLOAD_RC=1
  run deploy_one example "${MANIFEST}" 0
  assert_failure
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == 'download local ubuntu-22.04-standard_22.04-2_amd64.tar.zst' ]]
  [[ ! -e "${BATS_TEST_TMPDIR}/spec-called" ]]
}

@test "template fails when a successful download leaves the selected volume absent" {
  MISSING_VOLUME=1
  run deploy_one example "${MANIFEST}" 0
  assert_failure
  [[ "$(tail -1 "${TEMPLATE_CALLS}")" == 'list local' ]]
  [[ ! -e "${BATS_TEST_TMPDIR}/spec-called" ]]
}
