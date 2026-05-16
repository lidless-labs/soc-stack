#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  export SOC_TEST_MODE=1
  source "${REPO_ROOT}/scripts/install.sh"
}

@test "build_manifest uses the manifest file when --manifest given" {
  local mfile="${BATS_TEST_TMPDIR}/m.json"
  cat > "${mfile}" <<'EOF'
{
  "components": ["wazuh", "misp"],
  "preset": "production",
  "network": { "bridge": "vmbr5", "storage": "fast-lvm", "ip_mode": "dhcp" },
  "vmid_start": 7000
}
EOF
  parse_args --manifest "${mfile}"
  local out
  out="$(build_manifest)"
  jq -e '.components | length == 2' <<< "${out}"
  jq -e '.components | contains(["wazuh","misp"])' <<< "${out}"
  jq -e '.preset == "production"' <<< "${out}"
  jq -e '.network.bridge == "vmbr5"' <<< "${out}"
  jq -e '.vmid_start == 7000' <<< "${out}"
}

@test "manifest mode + CLI flag override: flag wins for that key" {
  local mfile="${BATS_TEST_TMPDIR}/m.json"
  cat > "${mfile}" <<'EOF'
{
  "components": ["wazuh"],
  "preset": "minimal",
  "network": { "bridge": "vmbr0", "storage": "local-lvm", "ip_mode": "dhcp" }
}
EOF
  parse_args --manifest "${mfile}" --preset production
  local out
  out="$(build_manifest)"
  jq -e '.preset == "production"' <<< "${out}"   # CLI override wins
  jq -e '.components | contains(["wazuh"])' <<< "${out}"   # manifest preserved
}

@test "manifest mode rejects malformed JSON" {
  local mfile="${BATS_TEST_TMPDIR}/bad.json"
  echo '{ broken' > "${mfile}"
  parse_args --manifest "${mfile}"
  run build_manifest
  [[ "$status" -ne 0 ]]
}

@test "manifest mode rejects manifest with unknown component" {
  local mfile="${BATS_TEST_TMPDIR}/m.json"
  cat > "${mfile}" <<'EOF'
{
  "components": ["wazuh", "imaginary"],
  "preset": "standard",
  "network": { "bridge": "vmbr0", "ip_mode": "dhcp" }
}
EOF
  parse_args --manifest "${mfile}"
  run build_manifest
  [[ "$status" -ne 0 ]]
  [[ "${output}${stderr:-}" == *"imaginary"* || "${output}${stderr:-}" == *"unknown"* ]]
}
