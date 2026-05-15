#!/usr/bin/env bash
# scripts/install.sh - SOC Stack unified Proxmox installer (Plan 1 - wazuh only)
# Spec: docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md

set -euo pipefail

SOC_STACK_VERSION="0.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
# shellcheck disable=SC2034
COMPONENTS_DIR="${SCRIPT_DIR}/components"

# Defaults (used by parse_args, build_manifest, deploy_one, main)
# shellcheck disable=SC2034
OPT_COMPONENTS="all"
# shellcheck disable=SC2034
OPT_PRESET="standard"
# shellcheck disable=SC2034
OPT_BRIDGE="vmbr0"
# shellcheck disable=SC2034
OPT_STORAGE=""
# shellcheck disable=SC2034
OPT_IP_MODE="dhcp"
# shellcheck disable=SC2034
OPT_IP_RANGE=""
# shellcheck disable=SC2034
OPT_VLAN=""
# shellcheck disable=SC2034
OPT_VMID_START="0"
# shellcheck disable=SC2034
OPT_MANIFEST=""
# shellcheck disable=SC2034
OPT_STATE_DIR="/var/lib/soc-stack"
# shellcheck disable=SC2034
OPT_JSON_OUT="/root/soc-stack.json"
# shellcheck disable=SC2034
OPT_MCP_CONFIG_OUT="/root/mcp-clients.json"
OPT_LOG_FILE="/var/log/soc-stack-install.log"
# shellcheck disable=SC2034
OPT_DRY_RUN="0"
# shellcheck disable=SC2034
OPT_FORCE="0"
# shellcheck disable=SC2034
OPT_NO_INTEGRATE="0"
OPT_NON_INTERACTIVE=""

usage() {
  cat <<EOF
soc-stack v${SOC_STACK_VERSION}

Usage:
  sudo bash install.sh [flags]

Flags:
  --components LIST     CSV of components or "all" (default: all)
  --preset NAME         minimal|standard|production (default: standard)
  --bridge NAME         Proxmox bridge (default: vmbr0)
  --storage NAME        Storage pool (default: auto-detect)
  --ip-mode MODE        dhcp|static (default: dhcp)
  --ip-range CIDR       Required if --ip-mode=static
  --vlan TAG            Optional VLAN tag
  --vmid-start N        First VMID to allocate (default: next free)
  --manifest PATH       JSON manifest (alternative to flags)
  --state-dir PATH      State directory (default: /var/lib/soc-stack)
  --json-out PATH       Result JSON (default: /root/soc-stack.json)
  --mcp-config-out PATH MCP client config (default: /root/mcp-clients.json)
  --log-file PATH       Log file (default: /var/log/soc-stack-install.log)
  --dry-run             Validate + plan, do not deploy
  --force               Redeploy even if state shows complete
  --no-integrate        Skip cross-component wiring
  --non-interactive     Hard-fail on prompts (auto when stdin not a tty)
  --version             Print version and exit
EOF
}

# shellcheck disable=SC2034
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --components)        OPT_COMPONENTS="$2"; shift 2 ;;
      --preset)            OPT_PRESET="$2"; shift 2 ;;
      --bridge)            OPT_BRIDGE="$2"; shift 2 ;;
      --storage)           OPT_STORAGE="$2"; shift 2 ;;
      --ip-mode)           OPT_IP_MODE="$2"; shift 2 ;;
      --ip-range)          OPT_IP_RANGE="$2"; shift 2 ;;
      --vlan)              OPT_VLAN="$2"; shift 2 ;;
      --vmid-start)        OPT_VMID_START="$2"; shift 2 ;;
      --manifest)          OPT_MANIFEST="$2"; shift 2 ;;
      --state-dir)         OPT_STATE_DIR="$2"; shift 2 ;;
      --json-out)          OPT_JSON_OUT="$2"; shift 2 ;;
      --mcp-config-out)    OPT_MCP_CONFIG_OUT="$2"; shift 2 ;;
      --log-file)          OPT_LOG_FILE="$2"; shift 2 ;;
      --dry-run)           OPT_DRY_RUN="1"; shift ;;
      --force)             OPT_FORCE="1"; shift ;;
      --no-integrate)      OPT_NO_INTEGRATE="1"; shift ;;
      --non-interactive)   OPT_NON_INTERACTIVE="1"; shift ;;
      --version)           printf 'soc-stack v%s\n' "${SOC_STACK_VERSION}"; return 0 ;;
      --help|-h)           usage; return 0 ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; usage >&2; return 1 ;;
    esac
  done

  # Auto-set non-interactive when stdin not a TTY
  if [[ -z "${OPT_NON_INTERACTIVE}" ]]; then
    [[ -t 0 ]] && OPT_NON_INTERACTIVE="0" || OPT_NON_INTERACTIVE="1"
  fi
}

# shellcheck disable=SC1091
source_libs() {
  export SOC_LOG_FILE="${OPT_LOG_FILE}"
  export SOC_STATE_DIR="${OPT_STATE_DIR}"
  export SOC_SECRETS_DIR="${OPT_STATE_DIR}/secrets"

  source "${LIB_DIR}/logging.sh"
  source "${LIB_DIR}/secrets.sh"
  source "${LIB_DIR}/json-out.sh"
  source "${LIB_DIR}/idempotency.sh"
  source "${LIB_DIR}/network.sh"
  source "${LIB_DIR}/preflight.sh"
  source "${LIB_DIR}/lxc.sh"
  source "${LIB_DIR}/manifest.sh"
}

# Known components in canonical order
COMPONENTS_KNOWN=("wazuh" "thehive-cortex" "misp" "zeek-suricata" "dashboards" "mcp")

# expand_components <csv-or-all>
# Echoes space-separated component names in canonical order.
expand_components() {
  local input="$1"
  if [[ "${input}" == "all" ]]; then
    printf '%s' "${COMPONENTS_KNOWN[*]}"
    return 0
  fi
  local arr=()
  # IFS=, scoped only to the read command; restored to default (space)
  # before the final join via ${arr[*]}.
  IFS=',' read -r -a arr <<< "${input}"
  printf '%s' "${arr[*]}"
}

# build_manifest
# Reads OPT_* globals, returns a manifest JSON document on stdout.
# Returns non-zero with an error message if any component is unknown.
build_manifest() {
  local components_list
  components_list="$(expand_components "${OPT_COMPONENTS}")"

  # Validate each name
  local c
  # shellcheck disable=SC2086  # intentional word-splitting on space-separated list
  for c in ${components_list}; do
    local known=0
    local k
    for k in "${COMPONENTS_KNOWN[@]}"; do
      [[ "${k}" == "${c}" ]] && { known=1; break; }
    done
    if [[ "${known}" -ne 1 ]]; then
      printf 'unknown component: %s\n' "${c}" >&2
      return 1
    fi
  done

  # Build components array as JSON
  local components_json
  # shellcheck disable=SC2086  # intentional word-splitting on space-separated list
  components_json="$(printf '%s\n' ${components_list} | jq -R . | jq -s .)"

  jq -n \
    --argjson components "${components_json}" \
    --arg preset "${OPT_PRESET}" \
    --arg bridge "${OPT_BRIDGE}" \
    --arg storage "${OPT_STORAGE}" \
    --arg ip_mode "${OPT_IP_MODE}" \
    --arg ip_range "${OPT_IP_RANGE}" \
    --arg vlan "${OPT_VLAN}" \
    --argjson vmid_start "${OPT_VMID_START}" \
    '{
      components: $components,
      preset: $preset,
      network: {
        bridge: $bridge,
        storage: (if $storage == "" then null else $storage end),
        ip_mode: $ip_mode,
        ip_range: (if $ip_range == "" then null else $ip_range end),
        vlan: (if $vlan == "" then null else $vlan end)
      },
      vmid_start: $vmid_start
    }'
}

# main() stub - the full preflight + dispatch body lands in Task 25.
# This stub is intentionally minimal so tests for parse_args / build_manifest
# can source install.sh under SOC_TEST_MODE without triggering deployment logic.
main() {
  parse_args "$@" || return $?
  source_libs
  msg_info "soc-stack v${SOC_STACK_VERSION} starting (Plan 1)"
}

# Only run main when executed (not when sourced for tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${SOC_TEST_MODE:-}" ]]; then
  main "$@"
fi
