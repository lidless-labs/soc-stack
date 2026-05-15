#!/usr/bin/env bash
# Convenience runner for all bats unit tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${REPO_ROOT}/tests/vendor/bats-core/bin/bats" \
  --print-output-on-failure \
  --formatter pretty \
  "${SCRIPT_DIR}"/*.bats
