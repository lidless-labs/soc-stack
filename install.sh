#!/usr/bin/env bash
# install.sh - repo-root entrypoint
#
# Two invocation modes:
#   1) Local checkout:  sudo bash install.sh [flags]
#   2) curl piped:      curl -sSL .../install.sh | sudo bash -s -- [flags]
#
# In mode 2, we self-bootstrap by cloning the repo to /tmp and re-exec'ing
# scripts/install.sh from there.

set -euo pipefail

REPO_URL="${SOC_STACK_REPO_URL:-https://github.com/solomonneas/soc-stack.git}"
REPO_REF="${SOC_STACK_REPO_REF:-main}"
LOCAL_CACHE="/var/lib/soc-stack/repo"

# Detect mode: is there a scripts/install.sh next to this wrapper?
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || WRAPPER_DIR=""
if [[ -n "${WRAPPER_DIR}" ]] && [[ -f "${WRAPPER_DIR}/scripts/install.sh" ]]; then
  exec bash "${WRAPPER_DIR}/scripts/install.sh" "$@"
fi

# curl-piped mode: clone and re-exec
echo "[install.sh] bootstrapping soc-stack from ${REPO_URL} (ref ${REPO_REF})"
mkdir -p "$(dirname "${LOCAL_CACHE}")"
if [[ -d "${LOCAL_CACHE}/.git" ]]; then
  (cd "${LOCAL_CACHE}" && git fetch --quiet origin "${REPO_REF}" && git checkout --quiet "${REPO_REF}" && git pull --ff-only --quiet)
else
  rm -rf "${LOCAL_CACHE}"
  git clone --quiet --branch "${REPO_REF}" --depth 1 "${REPO_URL}" "${LOCAL_CACHE}"
fi

exec bash "${LOCAL_CACHE}/scripts/install.sh" "$@"
