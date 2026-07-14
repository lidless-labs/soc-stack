#!/usr/bin/env bash
# scripts/lib/secrets.sh - password generation + secret persistence
# Requires: lib/logging.sh sourced first
# Reads: SOC_SECRETS_DIR (default /var/lib/soc-stack/secrets)

: "${SOC_SECRETS_DIR:=/var/lib/soc-stack/secrets}"

# gen_password [length]
# Emits an alnum + safe-special password of given length (default 24).
# Safe chars only - no shell metacharacters that would need quoting.
#
# Implementation note: head closes its stdin after reading <len> bytes, so tr
# takes SIGPIPE. That writes a "Broken pipe" to stderr (discarded here) AND,
# under `set -o pipefail` (which the orchestrator sets), makes the whole
# pipeline exit 141 even though the read succeeded. Capturing the output and
# swallowing that expected failure with `|| true` stops a successful call from
# aborting a `set -e` caller; the length assertion then still fails loudly if
# /dev/urandom genuinely returned short.
gen_password() {
  local len="${1:-24}"
  local charset='A-Za-z0-9_+=.-'
  local out=""
  out="$(LC_ALL=C tr -dc "${charset}" </dev/urandom 2>/dev/null | head -c "${len}")" || true
  if (( ${#out} < len )); then
    msg_error "gen_password: produced ${#out}/${len} chars from /dev/urandom"
    return 1
  fi
  printf '%s' "${out}"
}

# store_secret <name> <value>
# Writes value to ${SOC_SECRETS_DIR}/<name>.txt with mode 0600.
store_secret() {
  local name="$1"
  local value="$2"
  local f="${SOC_SECRETS_DIR}/${name}.txt"

  # Subshell umask: dir and file are born private, no permissive window
  # between create and chmod even with a loose inherited umask.
  (
    umask 0077
    mkdir -p "${SOC_SECRETS_DIR}"
    chmod 700 "${SOC_SECRETS_DIR}" 2>/dev/null || true
    printf '%s' "${value}" > "${f}"
    chmod 600 "${f}"
  )
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
