#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_STATE_DIR}/state"
  source_lib logging
  source "${REPO_ROOT}/scripts/lib/json-out.sh"
}

@test "emit_mcp_config writes empty mcpServers when no mcp state present" {
  local out="${BATS_TEST_TMPDIR}/mcp.json"
  emit_mcp_config "${out}"
  jq -e '.mcpServers' "${out}" >/dev/null
  jq -e '.mcpServers | length == 0' "${out}"
  [[ "$(stat -c "%a" "${out}")" == "600" ]]
}

@test "emit_mcp_config reads mcp state and produces paste-ready config" {
  cat > "${SOC_STATE_DIR}/state/mcp.json" <<'EOF'
{
  "component": "mcp",
  "status": "deployed",
  "mcp_endpoints": [
    {"name": "wazuh", "url": "http://198.51.100.99:3001/sse", "token": "abc123"},
    {"name": "thehive", "url": "http://198.51.100.99:3002/sse", "token": "def456"}
  ]
}
EOF
  local out="${BATS_TEST_TMPDIR}/mcp.json"
  emit_mcp_config "${out}"
  jq -e '.mcpServers.wazuh.type == "sse"' "${out}"
  jq -e '.mcpServers.wazuh.url == "http://198.51.100.99:3001/sse"' "${out}"
  jq -e '.mcpServers.wazuh.headers.Authorization == "Bearer abc123"' "${out}"
  jq -e '.mcpServers.thehive.url == "http://198.51.100.99:3002/sse"' "${out}"
  jq -e '.raw_endpoints | length == 2' "${out}"
  jq -e '.comment' "${out}" >/dev/null
}

@test "emit_mcp_config preserves all 9 servers if present" {
  local servers='[]'
  for n in wazuh thehive cortex misp zeek suricata mitre rapid7 sophos; do
    servers="$(jq --arg n "$n" --arg url "http://198.51.100.99:3001/sse" --arg tok "tok-$n" \
      '. + [{name:$n,url:$url,token:$tok}]' <<< "${servers}")"
  done
  jq -n --argjson eps "${servers}" '{
    component: "mcp",
    status: "deployed",
    mcp_endpoints: $eps
  }' > "${SOC_STATE_DIR}/state/mcp.json"

  local out="${BATS_TEST_TMPDIR}/mcp.json"
  emit_mcp_config "${out}"
  jq -e '.mcpServers | length == 9' "${out}"
  jq -e '.mcpServers.sophos | has("url") and has("type") and has("headers")' "${out}"
}
