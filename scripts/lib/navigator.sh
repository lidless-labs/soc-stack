#!/usr/bin/env bash
# scripts/lib/navigator.sh - emit a MITRE ATT&CK Navigator coverage layer
# from deployed component state + the declarative attack-coverage map.
# Requires: jq, lib/json-out.sh (state_file helpers optional; uses SOC_STATE_DIR)

: "${SOC_STATE_DIR:=/var/lib/soc-stack}"

# Default coverage map lives next to this library.
_navigator_default_coverage_map() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/data/attack-coverage.json\n' "${here}"
}

: "${NAVIGATOR_COVERAGE_MAP:=$(_navigator_default_coverage_map)}"

# _navigator_component_deployed <name>
# Exit 0 when state file exists and status is exactly "deployed".
_navigator_component_deployed() {
  local name="$1"
  local f="${SOC_STATE_DIR}/state/${name}.json"
  [[ -f "${f}" ]] || return 1
  [[ "$(jq -r '.status // empty' "${f}")" == "deployed" ]]
}

# _navigator_integration_eligible <wired_by> <from> <to> <type>
# An integration contributes coverage only when:
#   1. from and to components are deployed
#   2. wired_by's integration.status is exactly "integrated" (failed/missing skip)
#   3. If wired_by records a matching .integrations[] entry, it must be status=configured
_navigator_integration_eligible() {
  local wired_by="$1"
  local from="$2"
  local to="$3"
  local type="$4"
  local f entry_status integ_status

  _navigator_component_deployed "${from}" || return 1
  _navigator_component_deployed "${to}" || return 1

  f="${SOC_STATE_DIR}/state/${wired_by}.json"
  [[ -f "${f}" ]] || return 1

  integ_status="$(jq -r '.integration.status // empty' "${f}")"
  [[ "${integ_status}" == "integrated" ]] || return 1

  # If a matching per-link record exists, require configured (skip failed/pending).
  entry_status="$(jq -r --arg to "${to}" --arg type "${type}" '
    (.integrations // [])
    | map(select(.to == $to and .type == $type))
    | .[0].status // empty
  ' "${f}")"
  if [[ -n "${entry_status}" && "${entry_status}" != "configured" ]]; then
    return 1
  fi
  return 0
}

# _navigator_accumulate_techniques <coverage_json> <sources_json>
# sources_json: [{kind,id,display_name}]
# Prints technique accumulator JSON: { "T1059": {score, comments:[], sources:[]} }
_navigator_accumulate_techniques() {
  local coverage_json="$1"
  local sources_json="$2"

  jq -n --argjson cov "${coverage_json}" --argjson sources "${sources_json}" '
    def add_tech($acc; $tid; $src; $comment):
      ($acc[$tid] // {score: 0, sources: [], comments: []}) as $cur
      | $acc + {
          ($tid): {
            score: ($cur.score + 1),
            sources: ($cur.sources + [$src] | unique),
            comments: ($cur.comments + [
              (if ($comment | length) > 0 then "\($src): \($comment)" else $src end)
            ] | unique)
          }
        };

    reduce $sources[] as $s ({};
      if $s.kind == "component" then
        (($cov.components[$s.id].techniques // []) ) as $techs
        | reduce $techs[] as $t (.;
            add_tech(.; $t.id; $s.display_name; ($t.comment // ""))
          )
      elif $s.kind == "integration" then
        (($cov.integrations[$s.id].techniques // []) ) as $techs
        | reduce $techs[] as $t (.;
            add_tech(.; $t.id; $s.display_name; ($t.comment // ""))
          )
      else . end
    )
  '
}

# _navigator_collect_sources <coverage_json>
# Walk state dir against the coverage map; print JSON array of contributing sources.
_navigator_collect_sources() {
  local coverage_json="$1"
  local sources='[]'
  local name display integ_id from to type wired_by display_i

  # Components
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if _navigator_component_deployed "${name}"; then
      display="$(jq -r --arg n "${name}" '.components[$n].display_name // $n' <<< "${coverage_json}")"
      sources="$(jq --arg id "${name}" --arg d "${display}" \
        '. + [{kind:"component", id:$id, display_name:$d}]' <<< "${sources}")"
    fi
  done < <(jq -r '.components | keys[]' <<< "${coverage_json}")

  # Integrations
  while IFS= read -r integ_id; do
    [[ -n "${integ_id}" ]] || continue
    from="$(jq -r --arg id "${integ_id}" '.integrations[$id].from' <<< "${coverage_json}")"
    to="$(jq -r --arg id "${integ_id}" '.integrations[$id].to' <<< "${coverage_json}")"
    type="$(jq -r --arg id "${integ_id}" '.integrations[$id].type' <<< "${coverage_json}")"
    wired_by="$(jq -r --arg id "${integ_id}" '.integrations[$id].wired_by' <<< "${coverage_json}")"
    if _navigator_integration_eligible "${wired_by}" "${from}" "${to}" "${type}"; then
      display_i="$(jq -r --arg id "${integ_id}" '.integrations[$id].display_name // $id' <<< "${coverage_json}")"
      sources="$(jq --arg id "${integ_id}" --arg d "${display_i}" \
        '. + [{kind:"integration", id:$id, display_name:$d}]' <<< "${sources}")"
    fi
  done < <(jq -r '.integrations | keys[]' <<< "${coverage_json}")

  printf '%s\n' "${sources}"
}

# emit_navigator_layer <output_path> [coverage_map_path]
# Reads SOC_STATE_DIR component state and writes a Navigator layer JSON (v4.5).
# Always writes a valid layer (possibly with empty techniques) so operators can
# import a blank coverage view after a partial install.
emit_navigator_layer() {
  local out="$1"
  local map_path="${2:-${NAVIGATOR_COVERAGE_MAP}}"
  local coverage_json sources_json tech_acc max_score
  local installed_at parent

  if [[ -z "${out}" ]]; then
    printf 'emit_navigator_layer: output path required\n' >&2
    return 1
  fi
  if [[ ! -f "${map_path}" ]]; then
    printf 'emit_navigator_layer: coverage map not found: %s\n' "${map_path}" >&2
    return 1
  fi
  if ! coverage_json="$(jq -c . "${map_path}" 2>/dev/null)"; then
    printf 'emit_navigator_layer: coverage map is not valid JSON: %s\n' "${map_path}" >&2
    return 1
  fi

  parent="$(dirname "${out}")"
  if [[ "${parent}" != "." ]]; then
    mkdir -p "${parent}"
    chmod 700 "${parent}" 2>/dev/null || true
  fi

  sources_json="$(_navigator_collect_sources "${coverage_json}")"
  tech_acc="$(_navigator_accumulate_techniques "${coverage_json}" "${sources_json}")"
  max_score="$(jq '[.[].score] | max // 1' <<< "${tech_acc}")"
  if [[ "${max_score}" -lt 1 ]]; then
    max_score=1
  fi
  installed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  jq -n \
    --argjson cov "${coverage_json}" \
    --argjson acc "${tech_acc}" \
    --argjson sources "${sources_json}" \
    --argjson max_score "${max_score}" \
    --arg generated_at "${installed_at}" \
    --arg soc_stack_version "${SOC_STACK_VERSION:-1.0.0}" \
    '
    ($acc | to_entries | map({
      techniqueID: .key,
      score: .value.score,
      comment: (.value.comments | join("; ")),
      enabled: true,
      showSubtechniques: false
    }) | sort_by(.techniqueID)) as $techniques
    | {
        name: $cov.name,
        versions: {
          attack: ($cov.attack_version | tostring),
          navigator: $cov.navigator_version,
          layer: $cov.layer_version
        },
        domain: $cov.domain,
        description: $cov.description,
        filters: {
          platforms: ["Windows", "Linux", "macOS", "Network"]
        },
        sorting: 3,
        layout: {
          layout: "side",
          aggregateFunction: "average",
          showID: true,
          showName: true,
          showAggregateScores: false,
          countUnscored: false,
          expandedSubtechniques: "annotated"
        },
        hideDisabled: false,
        techniques: $techniques,
        gradient: {
          colors: ["#ffffff", "#90caf9", "#1565c0"],
          minValue: 0,
          maxValue: $max_score
        },
        legendItems: [
          {label: "1 contributing source", color: "#90caf9"},
          {label: "Multiple contributing sources", color: "#1565c0"}
        ],
        metadata: [
          {name: "generated_by", value: "soc-stack"},
          {name: "soc_stack_version", value: $soc_stack_version},
          {name: "generated_at", value: $generated_at},
          {name: "contributing_sources", value: ($sources | map(.display_name) | join(", "))}
        ],
        selectTechniquesAcrossTactics: true,
        selectSubtechniquesWithParent: false,
        selectVisibleTechniques: false
      }
    ' > "${out}"

  chmod 600 "${out}" 2>/dev/null || true
}
