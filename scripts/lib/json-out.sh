#!/usr/bin/env bash
# scripts/lib/json-out.sh - component state files + final result JSON emitter
# Requires: jq, lib/logging.sh

: "${SOC_STATE_DIR:=/var/lib/soc-stack}"

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

  mkdir -p "$(dirname "${f}")"
  [[ -f "${f}" ]] || echo '{}' > "${f}"

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

# emit_final_json <output_path>
# Reads all components' state files and writes a unified result JSON.
emit_final_json() {
  local out="$1"
  local installed_at
  installed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local components_array='[]'
  if compgen -G "${SOC_STATE_DIR}/state/*.json" >/dev/null; then
    # Build array by processing each state file with its filename
    local json_items=()
    for f in "${SOC_STATE_DIR}"/state/*.json; do
      local component_name
      component_name="$(basename "${f}" .json)"
      local obj
      obj="$(jq --arg name "${component_name}" '{name: $name} + .' "${f}")"
      json_items+=("${obj}")
    done
    components_array="$(printf '%s\n' "${json_items[@]}" | jq -s '.')"
  fi

  jq -n \
    --arg installed_at "${installed_at}" \
    --argjson components "${components_array}" \
    '{
      version: "1.0",
      installed_at: $installed_at,
      soc_stack_version: "0.5.0",
      components: $components,
      integrations: [],
      warnings: [],
      errors: []
    }' > "${out}"
}
