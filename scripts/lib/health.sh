#!/usr/bin/env bash
# scripts/lib/health.sh - opt-in, read-only post-install health report
# Reuses component verify.sh + state files. Non-destructive: no deploy/integrate/destroy.
# Requires: jq, lib/logging.sh, lib/json-out.sh, lib/lxc.sh, lib/idempotency.sh

: "${SOC_STATE_DIR:=/var/lib/soc-stack}"
: "${COMPONENTS_DIR:=}"
: "${HEALTH_ARTIFACT_MAX_AGE_SECONDS:=604800}" # 7 days
: "${HEALTH_REPORT_OUT:=${SOC_STATE_DIR}/health-report.json}"

# health_iso_now - UTC ISO-8601 timestamp
health_iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# health_components_dir - resolve components directory
health_components_dir() {
  if [[ -n "${COMPONENTS_DIR}" ]]; then
    printf '%s\n' "${COMPONENTS_DIR}"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s\n' "${here}/components"
}

# health_list_components [csv-or-all]
# Prints component names (one per line) that have state files, in canonical order
# when possible. If csv is set and not "all", restricts to that list (state optional).
health_list_components() {
  local input="${1:-all}"
  local known=("wazuh" "thehive-cortex" "misp" "zeek-suricata" "dashboards" "mcp")
  local selected=()

  if [[ "${input}" == "all" || -z "${input}" ]]; then
    local name
    for name in "${known[@]}"; do
      [[ -f "$(state_file "${name}")" ]] && selected+=("${name}")
    done
    # Include any unexpected state files not in known list
    local f base
    if compgen -G "${SOC_STATE_DIR}/state/*.json" >/dev/null; then
      for f in "${SOC_STATE_DIR}"/state/*.json; do
        base="$(basename "${f}" .json)"
        local found=0 k
        for k in "${selected[@]+"${selected[@]}"}"; do
          [[ "${k}" == "${base}" ]] && { found=1; break; }
        done
        for k in "${known[@]}"; do
          [[ "${k}" == "${base}" ]] && { found=1; break; }
        done
        [[ "${found}" -eq 0 ]] && selected+=("${base}")
      done
    fi
  else
    local csv arr=()
    csv="$(tr -d '[:space:]' <<< "${input}")"
    IFS=',' read -r -a arr <<< "${csv}"
    selected=("${arr[@]}")
  fi

  local c
  for c in "${selected[@]+"${selected[@]}"}"; do
    [[ -n "${c}" ]] && printf '%s\n' "${c}"
  done
}

# health_check_artifact <name> <path> [required:1|0]
# Prints a JSON object describing artifact existence, parseability, and freshness.
health_check_artifact() {
  local name="$1"
  local path="$2"
  local required="${3:-1}"
  local exists="false"
  local valid_json="false"
  local mtime=""
  local age_seconds=""
  local status="missing"
  local detail=""

  if [[ -f "${path}" ]]; then
    exists="true"
    if jq -e . "${path}" >/dev/null 2>&1; then
      valid_json="true"
      mtime="$(date -u -r "${path}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || stat -c '%y' "${path}" 2>/dev/null | awk '{print $1"T"$2"Z"}' || true)"
      local now epoch_mtime
      now="$(date +%s)"
      epoch_mtime="$(date -r "${path}" +%s 2>/dev/null || stat -c '%Y' "${path}" 2>/dev/null || echo "")"
      if [[ -n "${epoch_mtime}" ]]; then
        age_seconds=$((now - epoch_mtime))
        if (( age_seconds > HEALTH_ARTIFACT_MAX_AGE_SECONDS )); then
          status="stale"
          detail="artifact older than ${HEALTH_ARTIFACT_MAX_AGE_SECONDS}s"
        else
          status="ok"
        fi
      else
        status="ok"
      fi
    else
      status="malformed"
      detail="file exists but is not valid JSON"
    fi
  else
    if [[ "${required}" == "1" ]]; then
      status="missing"
      detail="required artifact not found"
    else
      status="absent"
      detail="optional artifact not found"
    fi
  fi

  jq -n \
    --arg name "${name}" \
    --arg path "${path}" \
    --argjson exists "${exists}" \
    --argjson valid_json "${valid_json}" \
    --arg mtime "${mtime}" \
    --arg age "${age_seconds}" \
    --arg status "${status}" \
    --arg detail "${detail}" \
    --argjson required "$([[ "${required}" == "1" ]] && echo true || echo false)" \
    '{
      name: $name,
      path: $path,
      required: $required,
      exists: $exists,
      valid_json: $valid_json,
      mtime: (if $mtime == "" then null else $mtime end),
      age_seconds: (if $age == "" then null else ($age | tonumber) end),
      status: $status,
      detail: (if $detail == "" then null else $detail end)
    }'
}

# health_probe_component <component>
# Non-destructive probe: state + LXC running + verify.sh (once) + integration.status.
# Prints one JSON object. Does not mutate state files.
health_probe_component() {
  local component="$1"
  local state_path
  state_path="$(state_file "${component}")"

  local state_status=""
  local vmid=""
  local hostname=""
  local integration_status=""
  local integrations_json='[]'

  if [[ -f "${state_path}" ]]; then
    if ! jq -e . "${state_path}" >/dev/null 2>&1; then
      jq -n --arg name "${component}" --arg path "${state_path}" '{
        name: $name,
        state_status: null,
        state_file: $path,
        lxc: { vmid: null, exists: false, running: false },
        verify: { status: "skipped", detail: "state file malformed" },
        integration: { status: "unknown" },
        integrations: [],
        observed_status: "unhealthy",
        detail: "state file is not valid JSON"
      }'
      return 0
    fi
    state_status="$(jq -r '.status // empty' "${state_path}")"
    vmid="$(jq -r '.lxc.vmid // empty' "${state_path}")"
    hostname="$(jq -r '.lxc.hostname // empty' "${state_path}")"
    integration_status="$(jq -r '.integration.status // empty' "${state_path}")"
    integrations_json="$(jq '.integrations // []' "${state_path}")"
  fi

  local lxc_exists="false"
  local lxc_running="false"
  local verify_status="skipped"
  local verify_detail=""
  local observed="unknown"
  local detail=""

  if [[ -z "${state_status}" ]]; then
    observed="not_deployed"
    detail="no state file"
    verify_detail="no state file"
  elif [[ "${state_status}" != "deployed" ]]; then
    observed="unhealthy"
    detail="state status is ${state_status}"
    verify_detail="component not in deployed state"
  elif [[ -z "${vmid}" ]]; then
    observed="unhealthy"
    detail="deployed but lxc.vmid missing from state"
    verify_detail="missing vmid"
  else
    if lxc_exists "${vmid}"; then
      lxc_exists="true"
    fi
    if lxc_running "${vmid}"; then
      lxc_running="true"
    fi

    if [[ "${lxc_exists}" != "true" ]]; then
      observed="unhealthy"
      detail="LXC ${vmid} does not exist"
      verify_detail="container missing"
    elif [[ "${lxc_running}" != "true" ]]; then
      # Running=false with failed/absent verify must not look healthy
      observed="unhealthy"
      detail="LXC ${vmid} is not running"
      verify_status="skipped"
      verify_detail="container not running"
    else
      local comps_dir verify_local remote_verify
      comps_dir="$(health_components_dir)"
      verify_local="${comps_dir}/${component}/verify.sh"
      if [[ ! -f "${verify_local}" ]]; then
        verify_status="skipped"
        verify_detail="verify.sh not found"
        observed="degraded"
        detail="no verify.sh for ${component}"
      else
        remote_verify="/tmp/soc-stack-health-${component}-verify.sh"
        if lxc_push_script "${vmid}" "${verify_local}" "${remote_verify}" \
          && pct exec "${vmid}" -- bash "${remote_verify}"; then
          verify_status="pass"
          verify_detail="verify.sh exited 0"
          # Integration soft-failures are degraded, not healthy-wash
          case "${integration_status}" in
            failed)
              observed="degraded"
              detail="services healthy but integration.status=failed"
              ;;
            "")
              observed="healthy"
              detail="verify passed; integration status unset"
              ;;
            *)
              observed="healthy"
              detail="verify passed"
              ;;
          esac
        else
          # Critical false-healthy path: running CT + failed service probe
          verify_status="fail"
          verify_detail="verify.sh exited non-zero"
          observed="unhealthy"
          detail="LXC running but verify.sh failed"
        fi
      fi
    fi
  fi

  local integ_status_out="${integration_status:-unknown}"
  [[ -z "${integration_status}" ]] && integ_status_out="unknown"

  jq -n \
    --arg name "${component}" \
    --arg state_status "${state_status}" \
    --arg state_file "${state_path}" \
    --arg vmid "${vmid}" \
    --arg hostname "${hostname}" \
    --argjson lxc_exists "${lxc_exists}" \
    --argjson lxc_running "${lxc_running}" \
    --arg verify_status "${verify_status}" \
    --arg verify_detail "${verify_detail}" \
    --arg integ "${integ_status_out}" \
    --argjson integrations "${integrations_json}" \
    --arg observed "${observed}" \
    --arg detail "${detail}" \
    '{
      name: $name,
      state_status: (if $state_status == "" then null else $state_status end),
      state_file: $state_file,
      lxc: {
        vmid: (if $vmid == "" then null else ($vmid | tonumber? // $vmid) end),
        hostname: (if $hostname == "" then null else $hostname end),
        exists: $lxc_exists,
        running: $lxc_running
      },
      verify: { status: $verify_status, detail: $verify_detail },
      integration: { status: $integ },
      integrations: $integrations,
      observed_status: $observed,
      detail: (if $detail == "" then null else $detail end)
    }'
}

# health_overall_status <components_json> <artifacts_json>
# Derive overall status. Missing/malformed required artifacts prevent "healthy".
health_overall_status() {
  local components_json="$1"
  local artifacts_json="$2"

  local bad_artifacts
  bad_artifacts="$(jq '[.[] | select(.required == true and .status != "ok" and .status != "stale")] | length' <<< "${artifacts_json}")"
  local stale_artifacts
  stale_artifacts="$(jq '[.[] | select(.required == true and .status == "stale")] | length' <<< "${artifacts_json}")"

  local unhealthy degraded healthy total
  unhealthy="$(jq '[.[] | select(.observed_status == "unhealthy")] | length' <<< "${components_json}")"
  degraded="$(jq '[.[] | select(.observed_status == "degraded")] | length' <<< "${components_json}")"
  healthy="$(jq '[.[] | select(.observed_status == "healthy")] | length' <<< "${components_json}")"
  total="$(jq 'length' <<< "${components_json}")"

  if [[ "${total}" -eq 0 ]]; then
    printf 'unknown\n'
    return 0
  fi
  if [[ "${bad_artifacts}" -gt 0 ]]; then
    # Missing or malformed result artifact is never healthy
    printf 'unhealthy\n'
    return 0
  fi
  if [[ "${unhealthy}" -gt 0 ]]; then
    printf 'unhealthy\n'
    return 0
  fi
  if [[ "${degraded}" -gt 0 || "${stale_artifacts}" -gt 0 ]]; then
    printf 'degraded\n'
    return 0
  fi
  if [[ "${healthy}" -eq "${total}" ]]; then
    printf 'healthy\n'
    return 0
  fi
  printf 'degraded\n'
}

# emit_health_report <output_path> [components_csv] [result_json_path] [mcp_config_path]
# Writes health JSON to output_path and prints the same JSON to stdout.
# Exit 0 if overall healthy, 1 if degraded/unhealthy/unknown.
emit_health_report() {
  local out="${1:-${HEALTH_REPORT_OUT}}"
  local components_csv="${2:-all}"
  local result_json_path="${3:-/root/soc-stack.json}"
  local mcp_config_path="${4:-/root/mcp-clients.json}"

  secure_parent_dir "${out}"
  secure_dir "${SOC_STATE_DIR}"

  local checked_at
  checked_at="$(health_iso_now)"

  local comp_json_items=()
  local name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    comp_json_items+=("$(health_probe_component "${name}")")
  done < <(health_list_components "${components_csv}")

  local components_array='[]'
  if [[ ${#comp_json_items[@]} -gt 0 ]]; then
    components_array="$(printf '%s\n' "${comp_json_items[@]}" | jq -s '.')"
  fi

  local art_result art_mcp art_state
  art_result="$(health_check_artifact "result_json" "${result_json_path}" 1)"
  # MCP config is required only when mcp is among probed components
  local mcp_required=0
  if jq -e '.[] | select(.name == "mcp")' <<< "${components_array}" >/dev/null 2>&1; then
    mcp_required=1
  fi
  art_mcp="$(health_check_artifact "mcp_config" "${mcp_config_path}" "${mcp_required}")"
  if [[ -d "${SOC_STATE_DIR}/state" ]]; then
    art_state="$(jq -n --arg path "${SOC_STATE_DIR}/state" '{
      name: "state_dir",
      path: $path,
      required: true,
      exists: true,
      valid_json: true,
      mtime: null,
      age_seconds: null,
      status: "ok",
      detail: null
    }')"
  else
    art_state="$(jq -n --arg path "${SOC_STATE_DIR}/state" '{
      name: "state_dir",
      path: $path,
      required: true,
      exists: false,
      valid_json: false,
      mtime: null,
      age_seconds: null,
      status: "missing",
      detail: "state directory missing"
    }')"
  fi

  local artifacts_array
  artifacts_array="$(jq -s '.' <<< "$(printf '%s\n' "${art_result}" "${art_mcp}" "${art_state}")")"

  local overall
  overall="$(health_overall_status "${components_array}" "${artifacts_array}")"

  local summary
  summary="$(jq -n \
    --argjson comps "${components_array}" \
    --argjson arts "${artifacts_array}" \
    --arg overall "${overall}" \
    '{
      overall_status: $overall,
      component_counts: {
        total: ($comps | length),
        healthy: [$comps[] | select(.observed_status == "healthy")] | length,
        degraded: [$comps[] | select(.observed_status == "degraded")] | length,
        unhealthy: [$comps[] | select(.observed_status == "unhealthy")] | length,
        not_deployed: [$comps[] | select(.observed_status == "not_deployed")] | length,
        unknown: [$comps[] | select(.observed_status == "unknown")] | length
      },
      artifact_counts: {
        total: ($arts | length),
        ok: [$arts[] | select(.status == "ok")] | length,
        stale: [$arts[] | select(.status == "stale")] | length,
        missing: [$arts[] | select(.status == "missing")] | length,
        malformed: [$arts[] | select(.status == "malformed")] | length
      }
    }')"

  local report
  report="$(jq -n \
    --arg checked_at "${checked_at}" \
    --arg soc_stack_version "${SOC_STACK_VERSION:-1.0.0}" \
    --arg overall "${overall}" \
    --argjson components "${components_array}" \
    --argjson artifacts "${artifacts_array}" \
    --argjson summary "${summary}" \
    '{
      version: "1.0",
      kind: "health_report",
      checked_at: $checked_at,
      soc_stack_version: $soc_stack_version,
      overall_status: $overall,
      components: $components,
      artifacts: $artifacts,
      summary: $summary
    }')"

  printf '%s\n' "${report}" > "${out}"
  chmod 600 "${out}" 2>/dev/null || true
  printf '%s\n' "${report}"

  case "${overall}" in
    healthy) return 0 ;;
    *) return 1 ;;
  esac
}

# run_health_report - orchestrator entry; uses OPT_* when set
run_health_report() {
  local components_csv="${OPT_COMPONENTS:-all}"
  local out="${HEALTH_REPORT_OUT:-${SOC_STATE_DIR}/health-report.json}"
  if [[ -n "${OPT_HEALTH_REPORT_OUT:-}" ]]; then
    out="${OPT_HEALTH_REPORT_OUT}"
  fi
  local result_json="${OPT_JSON_OUT:-/root/soc-stack.json}"
  local mcp_config="${OPT_MCP_CONFIG_OUT:-/root/mcp-clients.json}"

  msg_info "running opt-in health report (read-only)"
  local rc=0
  emit_health_report "${out}" "${components_csv}" "${result_json}" "${mcp_config}" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    msg_ok "health report: healthy (written to ${out})"
  else
    msg_warn "health report: not healthy (written to ${out})"
  fi
  return "${rc}"
}
