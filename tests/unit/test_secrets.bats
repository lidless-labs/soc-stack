#!/usr/bin/env bats

load helpers/load.bash

setup() {
  export SOC_STATE_DIR="${BATS_TEST_TMPDIR}/var/lib/soc-stack"
  export SOC_SECRETS_DIR="${SOC_STATE_DIR}/secrets"
  export SOC_LOG_FILE="${BATS_TEST_TMPDIR}/soc-stack.log"
  mkdir -p "${SOC_SECRETS_DIR}" "$(dirname "${SOC_LOG_FILE}")"
  source_lib logging
  source_lib secrets
}

@test "gen_password defaults to 24 chars" {
  run gen_password
  assert_success
  [[ ${#output} -eq 24 ]]
}

@test "gen_password accepts explicit length" {
  run gen_password 40
  assert_success
  [[ ${#output} -eq 40 ]]
}

@test "gen_password produces only safe chars (alnum + a few specials, no shell metacharacters)" {
  for _ in 1 2 3 4 5; do
    pw="$(gen_password 64)"
    [[ "$pw" =~ ^[A-Za-z0-9_+=.-]+$ ]] || {
      echo "FAIL: bad chars in $pw"
      false
    }
  done
}

@test "store_secret writes mode 0600 file" {
  store_secret "wazuh-admin" "hunter2"
  local f="${SOC_SECRETS_DIR}/wazuh-admin.txt"
  [[ -f "$f" ]]
  [[ "$(stat -c '%a' "$f")" == "600" ]]
  [[ "$(stat -c '%a' "${SOC_SECRETS_DIR}")" == "700" ]]
  [[ "$(cat "$f")" == "hunter2" ]]
}

@test "get_secret returns the stored value" {
  store_secret "thehive-admin" "swordfish"
  run get_secret "thehive-admin"
  assert_success
  assert_output "swordfish"
}

@test "get_secret returns empty on missing key" {
  run get_secret "does-not-exist"
  assert_success
  assert_output ""
}

@test "store_secret overwrites existing value" {
  store_secret "key1" "old"
  store_secret "key1" "new"
  run get_secret "key1"
  assert_output "new"
}
