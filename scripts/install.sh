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
# shellcheck disable=SC2034
OPT_EARLY_EXIT=0

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
      --version)           printf 'soc-stack v%s\n' "${SOC_STACK_VERSION}"; OPT_EARLY_EXIT=1; return 0 ;;
      --help|-h)           usage; OPT_EARLY_EXIT=1; return 0 ;;
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

# deploy_one <component> <manifest_json>
# Returns 0 if deployed (or already-deployed), non-zero on failure.
deploy_one() {
  local component="$1"
  local manifest="$2"

  msg_info "==== ${component} ===="

  if is_completed "${component}" && [[ "${OPT_FORCE}" != "1" ]]; then
    msg_ok "${component} already deployed (state status=deployed); skipping"
    return 0
  fi

  local preset bridge storage ip_mode
  preset="$(jq -r '.preset' <<< "${manifest}")"
  bridge="$(jq -r '.network.bridge' <<< "${manifest}")"
  storage="$(jq -r '.network.storage // "local-lvm"' <<< "${manifest}")"
  ip_mode="$(jq -r '.network.ip_mode' <<< "${manifest}")"

  # Get a VMID
  local vmid_start vmid
  vmid_start="$(jq -r '.vmid_start' <<< "${manifest}")"
  if [[ "${vmid_start}" == "0" ]] || [[ -z "${vmid_start}" ]]; then
    vmid="$(next_vmid 200)"
  else
    vmid="$(next_vmid "${vmid_start}")"
  fi

  # Build network config
  local net_config="name=eth0,bridge=${bridge}"
  case "${ip_mode}" in
    dhcp)   net_config+=",ip=dhcp" ;;
    static)
      local ip_range index ip
      ip_range="$(jq -r '.network.ip_range' <<< "${manifest}")"
      index=0  # Plan 1 single-component, index 0
      ip="$(allocate_ip "${ip_range}" "${index}")"
      net_config+=",ip=${ip}"
      ;;
  esac

  # Get template
  local template
  template="$(pveam list "${storage}" 2>/dev/null | awk '/ubuntu-22.04/{print $1; exit}')"
  if [[ -z "${template}" ]]; then
    template="$(pveam list local 2>/dev/null | awk '/ubuntu-22.04/{print $1; exit}')"
  fi
  if [[ -z "${template}" ]]; then
    msg_info "downloading Ubuntu 22.04 template"
    pveam update >/dev/null 2>&1 || true
    pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst >/dev/null 2>&1 || true
    template="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  fi

  # Get LXC spec from component
  local spec_lines
  spec_lines="$( SOC_PRESET="${preset}" \
                 SOC_NETWORK_CONFIG="${net_config}" \
                 SOC_STORAGE="${storage}" \
                 "${COMPONENTS_DIR}/${component}/lxc-spec.sh" )"

  # Generate root password
  local rootpw
  rootpw="$(gen_password 24)"
  store_secret "${component}-lxc-root" "${rootpw}"

  # Create LXC
  msg_info "creating LXC ${vmid} for ${component}"
  local pct_args=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    local part_arr=()
    read -r -a part_arr <<< "${line}"
    pct_args+=("${part_arr[@]}")
  done <<< "${spec_lines}"

  if [[ "${OPT_DRY_RUN}" == "1" ]]; then
    msg_info "[dry-run] would: pct create ${vmid} ${template} --hostname s3-${component} ${pct_args[*]} --password ***"
    return 0
  fi

  lxc_create "${vmid}" "s3-${component}" "${template}" "${pct_args[@]}" --password "${rootpw}"
  lxc_start "${vmid}"
  msg_info "waiting for LXC ${vmid} network"
  lxc_wait_network "${vmid}"

  # Persist LXC info to state up front
  state_set "${component}" "lxc.vmid" "${vmid}"
  state_set "${component}" "lxc.hostname" "s3-${component}"
  state_set "${component}" "preset" "${preset}"

  # Bind-mount state dir into LXC
  pct set "${vmid}" -mp0 "${SOC_STATE_DIR},mp=${SOC_STATE_DIR}"
  pct exec "${vmid}" -- mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}"

  # Push and run deploy.sh
  msg_info "running ${component}/deploy.sh inside LXC ${vmid}"
  local remote_deploy="/tmp/${component}-deploy.sh"
  lxc_push_script "${vmid}" "${COMPONENTS_DIR}/${component}/deploy.sh" "${remote_deploy}"

  if ! pct exec "${vmid}" -- env \
      SOC_STATE_DIR="${SOC_STATE_DIR}" \
      SOC_COMPONENT="${component}" \
      SOC_PRESET="${preset}" \
      SOC_NON_INTERACTIVE=1 \
      bash "${remote_deploy}"; then
    msg_error "${component} deploy.sh failed"
    state_set "${component}" status "failed"
    return 1
  fi

  # Run verify.sh
  msg_info "verifying ${component}"
  local remote_verify="/tmp/${component}-verify.sh"
  lxc_push_script "${vmid}" "${COMPONENTS_DIR}/${component}/verify.sh" "${remote_verify}"
  local retries=3
  local i=0
  while (( i < retries )); do
    if pct exec "${vmid}" -- bash "${remote_verify}"; then
      break
    fi
    i=$((i + 1))
    msg_warn "verify attempt ${i}/${retries} failed for ${component}, retrying in 30s"
    sleep 30
  done
  if (( i >= retries )); then
    msg_error "${component} verify.sh failed after ${retries} attempts"
    state_set "${component}" status "failed"
    return 1
  fi

  # Refresh state with the post-deploy IP
  local ip
  ip="$(lxc_ip "${vmid}")"
  if [[ -n "${ip}" ]]; then
    state_set "${component}" "lxc.ip" "${ip}"
  fi

  msg_ok "${component} deployed successfully"
  return 0
}

# integrate_all - run each deployed component's integrate.sh
integrate_all() {
  if [[ "${OPT_NO_INTEGRATE}" == "1" ]]; then
    msg_info "skipping integration phase (--no-integrate)"
    return 0
  fi
  local f
  for f in "${COMPONENTS_DIR}"/*/integrate.sh; do
    [[ -x "${f}" ]] || continue
    local comp_name
    comp_name="$(basename "$(dirname "${f}")")"
    if ! is_completed "${comp_name}"; then
      msg_info "skipping integrate.sh for ${comp_name} (not deployed)"
      continue
    fi
    msg_info "running ${comp_name}/integrate.sh"
    SOC_STATE_DIR="${SOC_STATE_DIR}" "${f}" || msg_warn "${comp_name} integrate.sh returned non-zero"
  done
}

main() {
  parse_args "$@" || return $?
  [[ "${OPT_EARLY_EXIT}" == "1" ]] && return 0
  source_libs

  msg_info "soc-stack v${SOC_STACK_VERSION} starting"

  # Pre-flight
  check_root          || return 1
  check_proxmox_version || return 1
  bootstrap_deps      || return 1
  check_deps          || return 1
  check_bridge "${OPT_BRIDGE}" || return 1
  if [[ -n "${OPT_STORAGE}" ]]; then
    check_storage "${OPT_STORAGE}" || return 1
  fi

  # Build manifest
  local manifest
  manifest="$(build_manifest)" || return 1

  if [[ "${OPT_DRY_RUN}" == "1" ]]; then
    msg_info "[dry-run] effective manifest:"
    jq <<< "${manifest}"
  fi

  # Deploy each component in canonical order (Plan 1 effectively wazuh only)
  local exit_status=0
  local components_arr=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && components_arr+=("${line}")
  done < <(jq -r '.components[]' <<< "${manifest}")

  local component
  for component in "${components_arr[@]}"; do
    if ! deploy_one "${component}" "${manifest}"; then
      exit_status=3
    fi
  done

  # Only mark completed if verify passed (set inside deploy_one upon success
  # via state file; this confirms via is_completed check)
  for component in "${components_arr[@]}"; do
    if [[ "$(state_get "${component}" status)" == "deployed" ]]; then
      mark_completed "${component}" || true
    fi
  done

  # Integration phase
  integrate_all

  # Emit results
  emit_final_json "${OPT_JSON_OUT}"
  msg_ok "result JSON written to ${OPT_JSON_OUT}"

  return "${exit_status}"
}

# Only run main when executed (not when sourced for tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${SOC_TEST_MODE:-}" ]]; then
  main "$@"
fi
