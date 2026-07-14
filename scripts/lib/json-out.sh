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

  # A corrupt existing state file (e.g. a partial write from an earlier crash)
  # would make the jq edit below fail. Without a guard, the unconditional mv
  # then truncated the file to empty and idempotency was lost forever. Re-seed
  # from {} so the edit proceeds and only this one update is missing, not all
  # of the recorded state.
  if [[ -s "${f}" ]] && ! jq -e . "${f}" >/dev/null 2>&1; then
    msg_warn "state file ${f} was not valid JSON; reinitializing"
    echo '{}' > "${f}"
    chmod 600 "${f}" 2>/dev/null || true
  fi

  # Try to parse value as JSON; if it fails, treat as string
  local jq_value
  if printf '%s' "${value}" | jq -e . >/dev/null 2>&1; then
    jq_value="${value}"
  else
    jq_value="$(printf '%s' "${value}" | jq -R '.')"
  fi

  # Write to a temp file in the SAME directory as the target so the final mv is
  # an atomic same-filesystem rename (mktemp under $TMPDIR could land on a
  # different filesystem, degrading mv to a non-atomic copy+unlink). Replace the
  # target only if jq actually succeeded; otherwise keep the old file intact.
  # Pass the key via --arg rather than interpolating it into the jq program, so
  # a key containing jq metacharacters cannot alter the filter.
  local tmp
  tmp="$(mktemp "${f}.XXXXXX")"
  if jq --argjson v "${jq_value}" --arg k "${key}" \
       'setpath($k | split("."); $v)' "${f}" > "${tmp}"; then
    mv "${tmp}" "${f}"
    chmod 600 "${f}" 2>/dev/null || true
  else
    rm -f "${tmp}"
    msg_error "state_set: failed to update ${f} (key=${key})"
    return 1
  fi
}

# state_get <component> <key>
# Prints the value at key, or empty if missing.
state_get() {
  local component="$1"
  local key="$2"
  local f
  f="$(state_file "${component}")"
  [[ -f "${f}" ]] || return 0
  # A corrupt state file must read as "empty" (and not abort a `set -e` caller
  # such as is_completed), so swallow jq failures. Key passed via --arg to keep
  # jq metacharacters in the key from altering the filter.
  jq -r --arg k "${key}" 'getpath($k | split(".")) // empty' "${f}" 2>/dev/null || true
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
    # Key-name match is a heuristic; it stays broad on purpose because a new
    # component author who names a field pw/passwd/bearer/credential should not
    # silently leak it into the default (redacted) result JSON. See
    # docs/adding-a-component.md for the naming contract.
    def secret_key: test("(pass(word|phrase|wd)?|pwd|api_?key|apikey|secret|token|authorization|bearer|credential|private_?key)"; "i");
    def redact:
      if type == "object" then
        with_entries(
          # Redact a matching key only when its value is a scalar. If it holds an
          # object/array (e.g. "credentials": {...}) keep recursing so the nested
          # secrets are redacted by their own keys and the shape is preserved.
          if (.key | secret_key) and ((.value | type) != "object") and ((.value | type) != "array") then
            .value = "REDACTED"
          else
            .value |= redact
          end
        )
      elif type == "array" then
        map(redact)
      elif type == "string" then
        # Scrub credentials embedded in a URL value (scheme://user:pass@host),
        # which no key-name check would ever catch.
        gsub("(?<u>://[^:/@[:space:]]+:)(?<p>[^@/[:space:]]+)(?<a>@)"; "\(.u)REDACTED\(.a)")
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
