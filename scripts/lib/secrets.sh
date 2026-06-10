#!/usr/bin/env bash
# scripts/lib/secrets.sh - password generation + secret persistence
# Requires: lib/logging.sh sourced first
# Reads: SOC_SECRETS_DIR (default /var/lib/soc-stack/secrets)

: "${SOC_SECRETS_DIR:=/var/lib/soc-stack/secrets}"

# gen_password [length]
# Emits an alnum + safe-special password of given length (default 24).
# Safe chars only - no shell metacharacters that would need quoting.
#
# Implementation note: head closes its stdin after reading <len> bytes,
# which causes tr to get SIGPIPE and write a "Broken pipe" error to stderr.
# In some environments (CI in particular) that error stream interleaves with
# the stdout capture. We discard tr's stderr to keep the output clean.
gen_password() {
  local len="${1:-24}"
  local charset='A-Za-z0-9_+=.-'
  LC_ALL=C tr -dc "${charset}" </dev/urandom 2>/dev/null | head -c "${len}"
}

# store_secret <name> <value>
# Writes value to ${SOC_SECRETS_DIR}/<name>.txt with mode 0600.
store_secret() {
  local name="$1"
  local value="$2"
  local f="${SOC_SECRETS_DIR}/${name}.txt"

  mkdir -p "${SOC_SECRETS_DIR}"
  chmod 700 "${SOC_SECRETS_DIR}" 2>/dev/null || true
  printf '%s' "${value}" > "${f}"
  chmod 600 "${f}"
}

# get_secret <name>
# Prints stored value to stdout, or empty string if missing.
get_secret() {
  local name="$1"
  local f="${SOC_SECRETS_DIR}/${name}.txt"
  if [[ -f "${f}" ]]; then
    cat "${f}"
  fi
}
