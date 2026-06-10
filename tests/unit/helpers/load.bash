#!/usr/bin/env bash
# Loaded at the top of every .bats file via `load helpers/load.bash`

# Make repo root available
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
export REPO_ROOT

# Load bats helpers
load "${REPO_ROOT}/tests/vendor/bats-support/load"
load "${REPO_ROOT}/tests/vendor/bats-assert/load"
bats_require_minimum_version 1.5.0

# Prepend fake-binary fixtures dir to PATH so mocks intercept calls
export PATH="${REPO_ROOT}/tests/unit/fixtures/bin:${PATH}"

# Per-test isolated state
setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}" "${SOC_STATE_DIR}/logs"
}

# Source a lib module under test
source_lib() {
  local module="$1"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/${module}.sh"
}
