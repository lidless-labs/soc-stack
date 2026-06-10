#!/usr/bin/env bash
# scripts/install.sh - SOC Stack unified Proxmox installer
# Spec: docs/superpowers/specs/2026-05-15-soc-stack-unification-design.md

set -euo pipefail

SOC_STACK_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
# shellcheck disable=SC2034
COMPONENTS_DIR="${SCRIPT_DIR}/components"

# Defaults (used by parse_args, build_manifest, deploy_one, main)
# shellcheck disable=SC2034
OPT_COMPONENTS="all"
OPT_COMPONENTS_SET="0"
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
OPT_INCLUDE_SECRETS_JSON="0"
OPT_MCP_BIND_HOST="127.0.0.1"
# shellcheck disable=SC2034
OPT_EARLY_EXIT=0
SOC_WARNINGS=()

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
  --include-secrets-json
                         Include raw credentials in result JSON (default: redacted)
  --mcp-bind-host HOST   MCP SSE bind host (default: 127.0.0.1; use 0.0.0.0 to expose)
  --version             Print version and exit
EOF
}

# shellcheck disable=SC2034
parse_args() {
  local flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --components|--preset|--bridge|--storage|--ip-mode|--ip-range|--vlan|--vmid-start|--manifest|--state-dir|--json-out|--mcp-config-out|--log-file|--mcp-bind-host)
        flag="$1"
        if [[ $# -lt 2 || "$2" == --* ]]; then
          printf 'missing value for %s\n' "${flag}" >&2
          usage >&2
          return 1
        fi
        case "${flag}" in
          --components)     OPT_COMPONENTS="$2"; OPT_COMPONENTS_SET="1" ;;
          --preset)         OPT_PRESET="$2" ;;
          --bridge)         OPT_BRIDGE="$2" ;;
          --storage)        OPT_STORAGE="$2" ;;
          --ip-mode)        OPT_IP_MODE="$2" ;;
          --ip-range)       OPT_IP_RANGE="$2" ;;
          --vlan)           OPT_VLAN="$2" ;;
          --vmid-start)     OPT_VMID_START="$2" ;;
          --manifest)       OPT_MANIFEST="$2" ;;
          --state-dir)      OPT_STATE_DIR="$2" ;;
          --json-out)       OPT_JSON_OUT="$2" ;;
          --mcp-config-out) OPT_MCP_CONFIG_OUT="$2" ;;
          --log-file)       OPT_LOG_FILE="$2" ;;
          --mcp-bind-host)  OPT_MCP_BIND_HOST="$2" ;;
        esac
        shift 2
        ;;
      --dry-run)           OPT_DRY_RUN="1"; shift ;;
      --force)             OPT_FORCE="1"; shift ;;
      --no-integrate)      OPT_NO_INTEGRATE="1"; shift ;;
      --non-interactive)   OPT_NON_INTERACTIVE="1"; shift ;;
      --include-secrets-json) OPT_INCLUDE_SECRETS_JSON="1"; shift ;;
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

validation_error() {
  printf '%s\n' "$*" >&2
}

validate_options() {
  case "${OPT_PRESET}" in
    minimal|standard|production) ;;
    *) validation_error "invalid preset: ${OPT_PRESET}"; return 1 ;;
  esac

  case "${OPT_IP_MODE}" in
    dhcp|static) ;;
    *) validation_error "invalid ip mode: ${OPT_IP_MODE}"; return 1 ;;
  esac

  if [[ "${OPT_IP_MODE}" == "static" ]]; then
    if [[ -z "${OPT_IP_RANGE}" ]]; then
      validation_error "--ip-range is required when --ip-mode=static"
      return 1
    fi
    if [[ ! "${OPT_IP_RANGE}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      validation_error "invalid ip range: ${OPT_IP_RANGE}"
      return 1
    fi
  fi

  if [[ ! "${OPT_VMID_START}" =~ ^[0-9]+$ ]]; then
    validation_error "invalid vmid start: ${OPT_VMID_START}"
    return 1
  fi

  if [[ -n "${OPT_VLAN}" ]]; then
    if [[ ! "${OPT_VLAN}" =~ ^[0-9]+$ ]] || (( OPT_VLAN < 1 || OPT_VLAN > 4094 )); then
      validation_error "invalid vlan tag: ${OPT_VLAN}"
      return 1
    fi
  fi

  if [[ -z "${OPT_MCP_BIND_HOST}" || ! "${OPT_MCP_BIND_HOST}" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    validation_error "invalid mcp bind host: ${OPT_MCP_BIND_HOST}"
    return 1
  fi
}

is_interactive_stdin() {
  [[ -t 0 || "${SOC_TEST_FORCE_TTY:-0}" == "1" ]]
}

maybe_pick_components() {
  if [[ "${OPT_NON_INTERACTIVE}" == "1" || "${OPT_COMPONENTS_SET}" == "1" || -n "${OPT_MANIFEST}" ]]; then
    return 0
  fi
  is_interactive_stdin || return 0

  local selected=()
  local i
  for i in "${!COMPONENTS_KNOWN[@]}"; do
    selected[i]=1
  done

  while true; do
    printf '\nSelect SOC Stack components. Press Enter to continue.\n' >&2
    for i in "${!COMPONENTS_KNOWN[@]}"; do
      local mark=" "
      [[ "${selected[i]}" == "1" ]] && mark="x"
      printf '  %d) [%s] %s\n' "$((i + 1))" "${mark}" "${COMPONENTS_KNOWN[i]}" >&2
    done
    printf 'Toggle number, a=all, n=none, Enter=continue: ' >&2

    local choice
    IFS= read -r choice || return 0
    case "${choice}" in
      "")
        local picked=()
        for i in "${!COMPONENTS_KNOWN[@]}"; do
          [[ "${selected[i]}" == "1" ]] && picked+=("${COMPONENTS_KNOWN[i]}")
        done
        if [[ ${#picked[@]} -eq 0 ]]; then
          printf 'Select at least one component.\n' >&2
          continue
        fi
        local csv
        csv="$(IFS=,; printf '%s' "${picked[*]}")"
        OPT_COMPONENTS="${csv}"
        OPT_COMPONENTS_SET="1"
        return 0
        ;;
      a|A)
        for i in "${!COMPONENTS_KNOWN[@]}"; do selected[i]=1; done
        ;;
      n|N)
        for i in "${!COMPONENTS_KNOWN[@]}"; do selected[i]=0; done
        ;;
      [1-9]*)
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#COMPONENTS_KNOWN[@]} )); then
          i=$((choice - 1))
          [[ "${selected[i]}" == "1" ]] && selected[i]=0 || selected[i]=1
        else
          printf 'Invalid selection: %s\n' "${choice}" >&2
        fi
        ;;
      *)
        printf 'Invalid selection: %s\n' "${choice}" >&2
        ;;
    esac
  done
}

# shellcheck disable=SC1091
source_libs() {
  export SOC_LOG_FILE="${OPT_LOG_FILE}"
  export SOC_STATE_DIR="${OPT_STATE_DIR}"
  export SOC_SECRETS_DIR="${OPT_STATE_DIR}/secrets"
  export SOC_STACK_VERSION

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
  input="$(tr -d '[:space:]' <<< "${input}")"
  local arr=()
  # IFS=, scoped only to the read command; restored to default (space)
  # before the final join via ${arr[*]}.
  IFS=',' read -r -a arr <<< "${input}"
  printf '%s' "${arr[*]}"
}

validate_components_json() {
  local manifest="$1"
  if ! jq -e '.components | type == "array" and length > 0' <<< "${manifest}" >/dev/null; then
    printf 'manifest components must be a non-empty array\n' >&2
    return 1
  fi

  local seen=" "
  local c
  while IFS= read -r c; do
    [[ -n "${c}" ]] || { printf 'component name cannot be empty\n' >&2; return 1; }
    if [[ "${seen}" == *" ${c} "* ]]; then
      printf 'duplicate component: %s\n' "${c}" >&2
      return 1
    fi
    seen+="${c} "
    local known=0
    local k
    for k in "${COMPONENTS_KNOWN[@]}"; do
      [[ "${k}" == "${c}" ]] && { known=1; break; }
    done
    if [[ "${known}" -ne 1 ]]; then
      printf 'unknown component: %s\n' "${c}" >&2
      return 1
    fi
  done < <(jq -r '.components[]' <<< "${manifest}")
}

validate_manifest_values() {
  local manifest="$1"
  local preset ip_mode vmid_start ip_range vlan
  preset="$(jq -r '.preset // empty' <<< "${manifest}")"
  ip_mode="$(jq -r '.network.ip_mode // empty' <<< "${manifest}")"
  vmid_start="$(jq -r '.vmid_start // 0' <<< "${manifest}")"
  ip_range="$(jq -r '.network.ip_range // empty' <<< "${manifest}")"
  vlan="$(jq -r '.network.vlan // empty' <<< "${manifest}")"

  case "${preset}" in
    minimal|standard|production) ;;
    *) printf 'invalid preset: %s\n' "${preset}" >&2; return 1 ;;
  esac
  case "${ip_mode}" in
    dhcp|static) ;;
    *) printf 'invalid ip mode: %s\n' "${ip_mode}" >&2; return 1 ;;
  esac
  if [[ "${ip_mode}" == "static" && -z "${ip_range}" ]]; then
    printf 'manifest network.ip_range is required when network.ip_mode=static\n' >&2
    return 1
  fi
  if [[ ! "${vmid_start}" =~ ^[0-9]+$ ]]; then
    printf 'invalid vmid_start: %s\n' "${vmid_start}" >&2
    return 1
  fi
  if [[ -n "${vlan}" ]]; then
    if [[ ! "${vlan}" =~ ^[0-9]+$ ]] || (( vlan < 1 || vlan > 4094 )); then
      printf 'invalid vlan tag: %s\n' "${vlan}" >&2
      return 1
    fi
  fi
}

# build_manifest
# Returns a manifest JSON document on stdout.
#
# If OPT_MANIFEST is set, reads that file as the base and merges any non-default
# CLI overrides on top (only flags the user explicitly set override the manifest;
# default values do not).
#
# If OPT_MANIFEST is unset, constructs the manifest from OPT_* globals as before.
#
# Returns non-zero (with stderr message) on malformed manifest or unknown component.
build_manifest() {
  local manifest

  if [[ -n "${OPT_MANIFEST}" ]]; then
    if [[ ! -f "${OPT_MANIFEST}" ]]; then
      printf 'manifest file not found: %s\n' "${OPT_MANIFEST}" >&2
      return 1
    fi
    if ! manifest="$(jq -c . "${OPT_MANIFEST}" 2>/dev/null)"; then
      printf 'manifest is not valid JSON: %s\n' "${OPT_MANIFEST}" >&2
      return 1
    fi

    # Apply user-set CLI overrides. We detect "user set" by comparing OPT_* to
    # the documented defaults. Only non-default OPT_* values override.
    if [[ "${OPT_COMPONENTS}" != "all" ]]; then
      manifest="$(jq --arg v "${OPT_COMPONENTS}" '.components = ($v | split(","))' <<< "${manifest}")"
    fi
    if [[ "${OPT_PRESET}" != "standard" ]]; then
      manifest="$(jq --arg v "${OPT_PRESET}" '.preset = $v' <<< "${manifest}")"
    fi
    if [[ "${OPT_BRIDGE}" != "vmbr0" ]]; then
      manifest="$(jq --arg v "${OPT_BRIDGE}" '.network.bridge = $v' <<< "${manifest}")"
    fi
    if [[ -n "${OPT_STORAGE}" ]]; then
      manifest="$(jq --arg v "${OPT_STORAGE}" '.network.storage = $v' <<< "${manifest}")"
    fi
    if [[ "${OPT_IP_MODE}" != "dhcp" ]]; then
      manifest="$(jq --arg v "${OPT_IP_MODE}" '.network.ip_mode = $v' <<< "${manifest}")"
    fi
    if [[ -n "${OPT_IP_RANGE}" ]]; then
      manifest="$(jq --arg v "${OPT_IP_RANGE}" '.network.ip_range = $v' <<< "${manifest}")"
    fi
    if [[ -n "${OPT_VLAN}" ]]; then
      manifest="$(jq --arg v "${OPT_VLAN}" '.network.vlan = $v' <<< "${manifest}")"
    fi
    if [[ "${OPT_VMID_START}" != "0" ]]; then
      manifest="$(jq --argjson v "${OPT_VMID_START}" '.vmid_start = $v' <<< "${manifest}")"
    fi
    manifest="$(jq \
      --arg bridge "${OPT_BRIDGE}" \
      '.network = (.network // {}) |
       .network.bridge = (.network.bridge // $bridge) |
       .network.ip_mode = (.network.ip_mode // "dhcp") |
       .vmid_start = (.vmid_start // 0)' <<< "${manifest}")"
  else
    # Flag-only mode
    local components_list
    components_list="$(expand_components "${OPT_COMPONENTS}")"
    local components_json
    # shellcheck disable=SC2086
    components_json="$(printf '%s\n' ${components_list} | jq -R . | jq -s .)"

    manifest="$(jq -n \
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
      }')"
  fi

  validate_components_json "${manifest}" || return 1
  validate_manifest_values "${manifest}" || return 1

  printf '%s\n' "${manifest}"
}

selection_has() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

record_warning() {
  local message="$*"
  SOC_WARNINGS+=("${message}")
  if declare -F msg_warn >/dev/null 2>&1; then
    msg_warn "${message}"
  else
    printf 'WARN: %s\n' "${message}" >&2
  fi
}

component_available_after_plan() {
  local component="$1"; shift
  selection_has "${component}" "$@" || is_completed "${component}"
}

plan_dependency_warnings() {
  local selected=("$@")
  if selection_has mcp "${selected[@]}"; then
    local peer
    for peer in wazuh thehive-cortex misp zeek-suricata; do
      component_available_after_plan "${peer}" "${selected[@]}" || \
        record_warning "mcp selected without ${peer}; related MCP environment will remain unwired until that component is deployed"
    done
  fi
  if selection_has zeek-suricata "${selected[@]}"; then
    component_available_after_plan wazuh "${selected[@]}" || \
      record_warning "zeek-suricata selected without wazuh; Zeek logs will not forward to Wazuh until Wazuh is deployed"
    component_available_after_plan misp "${selected[@]}" || \
      record_warning "zeek-suricata selected without misp; Suricata will not consume MISP rules until MISP is deployed"
  fi
  if selection_has dashboards "${selected[@]}"; then
    component_available_after_plan zeek-suricata "${selected[@]}" || \
      record_warning "dashboards selected without zeek-suricata; Bro Hunter will start without live Zeek logs"
  fi
  if selection_has wazuh "${selected[@]}"; then
    component_available_after_plan thehive-cortex "${selected[@]}" || \
      record_warning "wazuh selected without thehive-cortex; Wazuh alerts will not forward to TheHive until TheHive is deployed"
  fi
}

warnings_json() {
  if [[ ${#SOC_WARNINGS[@]} -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${SOC_WARNINGS[@]}" | jq -R . | jq -s .
  fi
}

# deploy_one <component> <manifest_json>
# Returns 0 if deployed (or already-deployed), non-zero on failure.
deploy_one() {
  local component="$1"
  local manifest="$2"
  local index="$3"

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
      local ip_range ip
      ip_range="$(jq -r '.network.ip_range' <<< "${manifest}")"
      if ! ip="$(allocate_ip "${ip_range}" "${index}")"; then
        msg_error "${component}: static IP allocation failed for ${ip_range} index ${index}"
        state_set "${component}" status "failed"
        return 1
      fi
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

  # Generate root password only when an LXC will actually be created.
  local rootpw
  rootpw="$(gen_password 24)"
  store_secret "${component}-lxc-root" "${rootpw}"

  lxc_create "${vmid}" "s3-${component}" "${template}" "${pct_args[@]}" --password "${rootpw}"
  lxc_start "${vmid}"
  msg_info "waiting for LXC ${vmid} network"
  lxc_wait_network "${vmid}"

  # Create state dirs INSIDE the LXC (no bind-mount; orchestrator pulls back after)
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
      SOC_MCP_BIND_HOST="${OPT_MCP_BIND_HOST}" \
      bash "${remote_deploy}"; then
    msg_error "${component} deploy.sh failed"
    state_set "${component}" status "failed"
    return 1
  fi

  # Pull deploy outputs from the LXC into the host state dir
  mkdir -p "${SOC_STATE_DIR}/state" "${SOC_SECRETS_DIR}"
  local in_lxc_state="${SOC_STATE_DIR}/state/${component}.json"
  if pct exec "${vmid}" -- test -f "${in_lxc_state}"; then
    pct pull "${vmid}" "${in_lxc_state}" "${SOC_STATE_DIR}/state/${component}.json"
  fi
  # Pull any per-component secret files (best-effort)
  while IFS= read -r remote; do
    [[ -n "${remote}" ]] || continue
    local fname
    fname="$(basename "${remote}")"
    pct pull "${vmid}" "${remote}" "${SOC_SECRETS_DIR}/${fname}" 2>/dev/null || true
  done < <(pct exec "${vmid}" -- bash -c "ls ${SOC_SECRETS_DIR}/* 2>/dev/null" || true)

  # Persist LXC info into host state now (after pull, so we merge on top)
  state_set "${component}" "lxc.vmid" "${vmid}"
  state_set "${component}" "lxc.hostname" "s3-${component}"
  state_set "${component}" "preset" "${preset}"

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

# deploy_exit_status <failures> <successes>
# Exit-code contract: 0 = all deployed, 3 = all requested components failed,
# 5 = mixed state (some deployed, some failed). 4 (integration failed) is
# applied by main() after the integration phase.
deploy_exit_status() {
  local failures="$1"
  local successes="$2"
  if (( failures > 0 )); then
    if (( successes > 0 )); then
      printf '5'
    else
      printf '3'
    fi
  else
    printf '0'
  fi
}

# integrate_all - run each deployed component's integrate.sh
# Records integration.status in each component's state file and returns
# non-zero if any integrate.sh failed (drives exit codes 4/5).
integrate_all() {
  if [[ "${OPT_NO_INTEGRATE}" == "1" ]]; then
    msg_info "skipping integration phase (--no-integrate)"
    return 0
  fi
  local f
  local failures=0
  for f in "${COMPONENTS_DIR}"/*/integrate.sh; do
    [[ -x "${f}" ]] || continue
    local comp_name
    comp_name="$(basename "$(dirname "${f}")")"
    if ! is_completed "${comp_name}"; then
      msg_info "skipping integrate.sh for ${comp_name} (not deployed)"
      continue
    fi
    msg_info "running ${comp_name}/integrate.sh"
    if SOC_STATE_DIR="${SOC_STATE_DIR}" "${f}"; then
      state_set "${comp_name}" "integration.status" "integrated"
    else
      record_warning "${comp_name} integrate.sh returned non-zero"
      state_set "${comp_name}" "integration.status" "failed"
      failures=$((failures + 1))
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

main() {
  parse_args "$@" || return 2
  [[ "${OPT_EARLY_EXIT}" == "1" ]] && return 0
  validate_options || return 2
  maybe_pick_components || return 2
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
  manifest="$(build_manifest)" || return 2

  if [[ "${OPT_DRY_RUN}" == "1" ]]; then
    msg_info "[dry-run] effective manifest:"
    jq <<< "${manifest}"
  fi

  # Deploy each requested component.
  local exit_status=0
  local components_arr=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && components_arr+=("${line}")
  done < <(jq -r '.components[]' <<< "${manifest}")

  msg_info "deploy plan: ${components_arr[*]}"
  plan_dependency_warnings "${components_arr[@]}"

  local component
  local component_index=0
  local deploy_failures=0
  local deploy_successes=0
  for component in "${components_arr[@]}"; do
    if deploy_one "${component}" "${manifest}" "${component_index}"; then
      deploy_successes=$((deploy_successes + 1))
    else
      deploy_failures=$((deploy_failures + 1))
    fi
    component_index=$((component_index + 1))
  done

  exit_status="$(deploy_exit_status "${deploy_failures}" "${deploy_successes}")"

  # Only mark completed if verify passed (set inside deploy_one upon success
  # via state file; this confirms via is_completed check)
  for component in "${components_arr[@]}"; do
    if [[ "$(state_get "${component}" status)" == "deployed" ]]; then
      mark_completed "${component}" || true
    fi
  done

  # Integration phase
  local integrate_ok=1
  integrate_all || integrate_ok=0
  if (( integrate_ok == 0 )) && (( exit_status == 0 )); then
    exit_status=4
  fi

  # Emit results
  SOC_WARNINGS_JSON="$(warnings_json)" \
    emit_final_json "${OPT_JSON_OUT}" "${OPT_INCLUDE_SECRETS_JSON}"
  msg_ok "result JSON written to ${OPT_JSON_OUT}"

  emit_mcp_config "${OPT_MCP_CONFIG_OUT}"
  msg_ok "MCP client config written to ${OPT_MCP_CONFIG_OUT}"

  return "${exit_status}"
}

# Only run main when executed (not when sourced for tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${SOC_TEST_MODE:-}" ]]; then
  main "$@"
fi
