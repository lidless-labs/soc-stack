#!/usr/bin/env bash
# scripts/lib/manifest.sh - manifest parsing, validation, and flag merging
# Requires: jq

# parse_manifest <file> <jq-path-with-dots>
# Prints the value at the path. Returns empty for missing.
parse_manifest() {
  local file="$1"
  local key="$2"
  jq -r "getpath(\"${key}\" / \".\") // empty | (if type == \"array\" then join(\",\") else . end)" "${file}"
}

# validate_manifest <file>
# Returns 0 if valid; otherwise prints errors and returns non-zero.
validate_manifest() {
  local file="$1"
  if ! jq -e . "${file}" >/dev/null 2>&1; then
    msg_error "manifest is not valid JSON: ${file}"
    return 1
  fi

  local missing=()
  jq -e '.components' "${file}" >/dev/null 2>&1 || missing+=("components")
  jq -e '.preset' "${file}"     >/dev/null 2>&1 || missing+=("preset")

  if [[ ${#missing[@]} -gt 0 ]]; then
    msg_error "manifest missing required keys: ${missing[*]}"
    return 1
  fi

  # Each component must be a known name
  local known="wazuh thehive-cortex misp zeek-suricata dashboards mcp"
  local bad=()
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    if ! grep -qw "${c}" <<< "${known}"; then
      bad+=("${c}")
    fi
  done < <(jq -r '.components[]' "${file}")
  if [[ ${#bad[@]} -gt 0 ]]; then
    msg_error "unknown components: ${bad[*]}"
    return 1
  fi

  return 0
}

# merge_flags_into_manifest <file> [--flag value ...]
# Reads a base manifest, applies CLI flag overrides, prints merged JSON to stdout.
merge_flags_into_manifest() {
  local file="$1"; shift
  local m
  m="$(cat "${file}")"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --components)  m="$(jq --arg v "$2" '.components = ($v | split(","))' <<< "${m}")"; shift 2 ;;
      --preset)      m="$(jq --arg v "$2" '.preset = $v' <<< "${m}")"; shift 2 ;;
      --bridge)      m="$(jq --arg v "$2" '.network.bridge = $v' <<< "${m}")"; shift 2 ;;
      --storage)     m="$(jq --arg v "$2" '.network.storage = $v' <<< "${m}")"; shift 2 ;;
      --ip-mode)     m="$(jq --arg v "$2" '.network.ip_mode = $v' <<< "${m}")"; shift 2 ;;
      --ip-range)    m="$(jq --arg v "$2" '.network.ip_range = $v' <<< "${m}")"; shift 2 ;;
      --vlan)        m="$(jq --arg v "$2" '.network.vlan = $v' <<< "${m}")"; shift 2 ;;
      --vmid-start)  m="$(jq --argjson v "$2" '.vmid_start = $v' <<< "${m}")"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "${m}"
}

# build_manifest_from_flags [--flag value ...]
# Constructs a manifest from scratch using defaults + flags.
build_manifest_from_flags() {
  local base
  base='{
    "components": ["wazuh","thehive-cortex","misp","zeek-suricata","dashboards","mcp"],
    "preset": "standard",
    "network": {
      "bridge": "vmbr0",
      "storage": "local-lvm",
      "ip_mode": "dhcp"
    },
    "vmid_start": 0
  }'
  local tmp
  tmp="$(mktemp)"
  printf '%s' "${base}" > "${tmp}"
  merge_flags_into_manifest "${tmp}" "$@"
  rm -f "${tmp}"
}
