#!/usr/bin/env bats
# Exit-code contract + integration phase state tracking

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"

  # Point the orchestrator at a fake components dir we control
  COMPONENTS_DIR="${BATS_TEST_TMPDIR}/components"
  mkdir -p "${COMPONENTS_DIR}"

  parse_args --state-dir "${SOC_STATE_DIR}" --log-file "${SOC_LOG_FILE}"
  source_libs
}

# make_component <name> <integrate-exit-code> [deployed]
make_component() {
  local name="$1"
  local rc="$2"
  local deployed="${3:-yes}"
  mkdir -p "${COMPONENTS_DIR}/${name}"
  printf '#!/usr/bin/env bash\nexit %s\n' "${rc}" > "${COMPONENTS_DIR}/${name}/integrate.sh"
  chmod +x "${COMPONENTS_DIR}/${name}/integrate.sh"
  if [[ "${deployed}" == "yes" ]]; then
    state_set "${name}" status "deployed"
  fi
}

@test "deploy_exit_status: all succeeded -> 0" {
  run deploy_exit_status 0 3
  assert_success
  assert_output "0"
}

@test "deploy_exit_status: all failed -> 3" {
  run deploy_exit_status 2 0
  assert_success
  assert_output "3"
}

@test "deploy_exit_status: mixed -> 5" {
  run deploy_exit_status 1 2
  assert_success
  assert_output "5"
}

@test "integrate_all returns 0 when every integrate.sh succeeds" {
  make_component alpha 0
  make_component beta 0
  run integrate_all
  assert_success
}

@test "integrate_all returns non-zero when an integrate.sh fails" {
  make_component alpha 0
  make_component beta 1
  run integrate_all
  assert_failure
}

@test "integrate_all marks integration.status=integrated on success" {
  make_component alpha 0
  integrate_all
  [[ "$(state_get alpha "integration.status")" == "integrated" ]]
}

@test "integrate_all marks integration.status=failed on failure" {
  make_component alpha 1
  integrate_all || true
  [[ "$(state_get alpha "integration.status")" == "failed" ]]
}

@test "integrate_all records a warning for a failed integrate.sh" {
  make_component alpha 1
  integrate_all || true
  [[ ${#SOC_WARNINGS[@]} -gt 0 ]]
  [[ "${SOC_WARNINGS[0]}" == *"alpha"* ]]
}

@test "integrate_all skips components that are not deployed" {
  make_component alpha 1 no
  run integrate_all
  assert_success
  [[ -z "$(state_get alpha "integration.status")" ]]
}

@test "integrate_all is a no-op under --no-integrate" {
  make_component alpha 1
  OPT_NO_INTEGRATE=1
  run integrate_all
  assert_success
}
