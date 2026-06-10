#!/usr/bin/env bash
# scripts/lib/json-out.sh - component state files + final result JSON emitter
# Requires: jq, lib/logging.sh

: "${SOC_STATE_DIR:=/var/lib/soc-stack}"
: "${SOC_SECRETS_DIR:=${SOC_STATE_DIR}/secrets}"

secure_dir() {
  mkdir -p "$1"
  chmod 700 "$1" 2>/dev/null || true
}

secure_parent_dir() {
  local dir
  dir="$(dirname "$1")"
  [[ "${dir}" == "." ]] && return 0
  secure_dir "${dir}"
}

# state_file <component> - print path to that component's state file
state_file() {
  printf '%s/state/%s.json\n' "${SOC_STATE_DIR}" "$1"
}

# state_set <component> <key> <value>
# Key may use dot notation for nesting (e.g., "lxc.vmid").
# Value is interpreted as JSON if it parses, else as a string.
state_set() {
  local component="$1"
  local key="$2"
  local value="$3"
  local f
  f="$(state_file "${component}")"

  secure_dir "$(dirname "${f}")"
  [[ -f "${f}" ]] || { echo '{}' > "${f}"; chmod 600 "${f}" 2>/dev/null || true; }

  # Try to parse value as JSON; if it fails, treat as string
  local jq_value
  if printf '%s' "${value}" | jq -e . >/dev/null 2>&1; then
    jq_value="${value}"
  else
    jq_value="$(printf '%s' "${value}" | jq -R '.')"
  fi

  local tmp
  tmp="$(mktemp)"
  jq --argjson v "${jq_value}" "setpath(\"${key}\" | split(\".\"); \$v)" "${f}" > "${tmp}"
  mv "${tmp}" "${f}"
  chmod 600 "${f}" 2>/dev/null || true
}

# state_get <component> <key>
# Prints the value at key, or empty if missing.
state_get() {
  local component="$1"
  local key="$2"
  local f
  f="$(state_file "${component}")"
  [[ -f "${f}" ]] || return 0
  jq -r "getpath(\"${key}\" | split(\".\")) // empty" "${f}"
}

# component_secret_files_json <component>
component_secret_files_json() {
  local component="$1"
  local patterns=()
  case "${component}" in
    wazuh) patterns=("wazuh-*.txt") ;;
    thehive-cortex) patterns=("thehive-*.txt" "cortex-*.txt") ;;
    misp) patterns=("misp-*.txt") ;;
    mcp) patterns=("mcp-*.txt") ;;
    *) patterns=("${component}-*.txt") ;;
  esac

  local files=()
  local pattern path
  for pattern in "${patterns[@]}"; do
    while IFS= read -r path; do
      [[ -n "${path}" ]] && files+=("${path}")
    done < <(compgen -G "${SOC_SECRETS_DIR}/${pattern}" || true)
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${files[@]}" | jq -R . | jq -s .
  fi
}

redact_json() {
  jq '
    def redact:
      if type == "object" then
        with_entries(
          if (.key | test("(password|passphrase|api_?key|token|secret|authorization)"; "i")) then
            .value = "REDACTED"
          else
            .value |= redact
          end
        )
      elif type == "array" then
        map(redact)
      else
        .
      end;
    redact
  '
}

# emit_final_json <output_path> [include_secrets]
# Reads all components' state files and writes a unified result JSON.
emit_final_json() {
  local out="$1"
  local include_secrets="${2:-0}"
  local installed_at
  installed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  secure_parent_dir "${out}"
  secure_dir "${SOC_STATE_DIR}/state"
  secure_dir "${SOC_SECRETS_DIR}"

  local components_array='[]'
  if compgen -G "${SOC_STATE_DIR}/state/*.json" >/dev/null; then
    # Build array by processing each state file with its filename
    local json_items=()
    for f in "${SOC_STATE_DIR}"/state/*.json; do
      local component_name
      component_name="$(basename "${f}" .json)"
      local obj
      obj="$(jq --arg name "${component_name}" '{name: $name} + .' "${f}")"
      if [[ "${include_secrets}" != "1" ]]; then
        local secret_files
        secret_files="$(component_secret_files_json "${component_name}")"
        obj="$(redact_json <<< "${obj}" | jq --argjson files "${secret_files}" '. + {secret_files: $files}')"
      fi
      json_items+=("${obj}")
    done
    components_array="$(printf '%s\n' "${json_items[@]}" | jq -s '.')"
  fi

  local warnings_json="${SOC_WARNINGS_JSON:-[]}"

  jq -n \
    --arg installed_at "${installed_at}" \
    --arg soc_stack_version "${SOC_STACK_VERSION:-1.0.0}" \
    --argjson components "${components_array}" \
    --argjson warnings "${warnings_json}" \
    '{
      version: "1.0",
      installed_at: $installed_at,
      soc_stack_version: $soc_stack_version,
      components: $components,
      integrations: [],
      warnings: $warnings,
      errors: []
    }' > "${out}"
  chmod 600 "${out}" 2>/dev/null || true
}

# emit_mcp_config <output_path>
# Reads the mcp component's state file (if any) and writes a paste-ready
# MCP client config to <output_path>.
emit_mcp_config() {
  local out="$1"
  local mcp_state="${SOC_STATE_DIR}/state/mcp.json"

  secure_parent_dir "${out}"

  local endpoints='[]'
  if [[ -f "${mcp_state}" ]]; then
    endpoints="$(jq '.mcp_endpoints // []' "${mcp_state}")"
  fi

  jq -n --argjson eps "${endpoints}" '
    {
      comment: "Paste the mcpServers block into your MCP client config (Claude Desktop, OpenClaw, etc).",
      mcpServers: ($eps | map({(.name): {
        type: "sse",
        url: .url,
        headers: { Authorization: ("Bearer " + .token) }
      }}) | add // {}),
      raw_endpoints: $eps
    }' > "${out}"
  chmod 600 "${out}" 2>/dev/null || true
}
