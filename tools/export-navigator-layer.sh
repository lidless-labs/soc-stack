#!/usr/bin/env bash
# tools/export-navigator-layer.sh - regenerate an ATT&CK Navigator coverage
# layer from an existing soc-stack state directory (no redeploy required).
#
# Usage:
#   tools/export-navigator-layer.sh [--state-dir PATH] [--out PATH] [--coverage-map PATH]
#
# Defaults:
#   --state-dir /var/lib/soc-stack
#   --out       ./soc-stack-navigator.json
#   --coverage-map scripts/lib/data/attack-coverage.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPT_STATE_DIR="/var/lib/soc-stack"
OPT_OUT="./soc-stack-navigator.json"
OPT_COVERAGE_MAP="${REPO_ROOT}/scripts/lib/data/attack-coverage.json"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--state-dir PATH] [--out PATH] [--coverage-map PATH]

Regenerate a MITRE ATT&CK Navigator coverage layer from deployed soc-stack
state. Only components with status=deployed and integrations with
integration.status=integrated (and configured link records when present)
contribute techniques.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      [[ $# -ge 2 && "$2" != --* ]] || { printf 'missing value for %s\n' "$1" >&2; exit 1; }
      OPT_STATE_DIR="$2"; shift 2 ;;
    --out)
      [[ $# -ge 2 && "$2" != --* ]] || { printf 'missing value for %s\n' "$1" >&2; exit 1; }
      OPT_OUT="$2"; shift 2 ;;
    --coverage-map)
      [[ $# -ge 2 && "$2" != --* ]] || { printf 'missing value for %s\n' "$1" >&2; exit 1; }
      OPT_COVERAGE_MAP="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      printf 'unknown flag: %s\n' "$1" >&2
      usage >&2
      exit 1 ;;
  esac
done

export SOC_STATE_DIR="${OPT_STATE_DIR}"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/navigator.sh"

emit_navigator_layer "${OPT_OUT}" "${OPT_COVERAGE_MAP}"
printf 'navigator layer written to %s\n' "${OPT_OUT}"
