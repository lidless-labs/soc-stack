#!/usr/bin/env bash
# tools/package-verify.sh - read-only verification that a file on a Debian or
# Ubuntu host matches the file shipped in the distro package that owns it.
#
# Built to settle rootkit-scanner "trojaned binary" false positives (for
# example Wazuh rootcheck signatures hitting /usr/bin/passwd) with evidence
# instead of a shrug. See docs/package-verify.md.
#
# Usage:
#   tools/package-verify.sh --host <ssh-target> --path </abs/file>
#       [--pve-host <ssh-target> --ctid <id>] [--inside-via-pct]
#       [--format json|md] [--mirror <url>] [--keyring <path>]
#       [--no-archive-check] [--max-index-age-days <1..365>]
#
# Exit codes: 0 match (outside-verified), 1 mismatch, 2 package-unknown,
# 3 error/usage, 4 match-unverified (self-reported only).
set -euo pipefail

TOOL_VERSION="1.4.0"

usage() {
  cat <<EOF
Usage: $(basename "$0") --host <ssh-target> --path </abs/file> [options]

Verify that a file on a Debian/Ubuntu host is byte-identical to the file in the
distro package that owns it. Strictly read-only on every remote; the package is
downloaded to a private temp dir on this machine and the one needed file is
hashed by streaming it out of the archive. Nothing is extracted to disk,
installed, or executed.

Required:
  --host <ssh-target>   ssh destination of the machine that holds the file.
                        Optional when --inside-via-pct is used.
  --path </abs/file>    absolute CANONICAL path to verify (no symlinked
                        components; Debian /bin is a symlink, so pass
                        /usr/bin/...). Allowed characters: A-Z a-z 0-9 . _ + / -
                        ; no '..'. A non-canonical path is an error.

Optional:
  --pve-host <target>   ssh destination of the Proxmox host that runs the
                        container. With --ctid, adds an "outside" read of the
                        container root filesystem that does not trust the
                        container's own tools. Block-device rootfs only; a
                        directory-backed rootfs gives no outside view.
  --ctid <id>           container id (digits). Requires --pve-host.
  --inside-via-pct      run the inside commands in the container with
                        'pct exec' on --pve-host instead of ssh to --host
                        (for containers without their own sshd).
  --format json|md      output format (default json). md is a compact block
                        for a case comment.
  --mirror <url>        https archive base URL (default: derived from the
                        target's apt origin for debian/ubuntu archives; other
                        origins yield package-unknown).
  --keyring <path>      GPG keyring used to verify the archive InRelease
                        (default: debian-archive-keyring.gpg for Debian
                        origins, ubuntu-archive-keyring.gpg for Ubuntu
                        origins, both under /usr/share/keyrings, chosen from
                        the archive host; an unknown host needs --keyring).
  --no-archive-check    skip the archive signature check (archive_signature
                        is then not-verified, "disabled by --no-archive-check",
                        and a match stays a match as in v1.3).
  --max-index-age-days <n>
                        newest acceptable age of the signed index Date, 1..365
                        (default 14). An older or future-dated index is
                        not-verified.
  --help                show this help
  --version             show the tool version

Remote commands (all read-only): readlink, wc, sha256sum, dpkg -S,
dpkg-divert, dpkg-query, apt-cache show/policy. On the Proxmox host: pct config,
pvesm path, debugfs (read-only, no -w). It never mounts or writes.

Runner requirements: jq curl dpkg-deb tar ssh sha256sum timeout (a missing one
is an error, exit 3). Optional: gpgv, xz (or gzip) and an archive keyring; when
one is missing the archive signature check is skipped as not-verified, never an
error. Every package decoder and parser stage (dpkg-deb, tar,
the listing filter) runs under a timeout (PV_DECODER_TIMEOUT seconds, 1..3600,
default 120) and a virtual memory cap (PV_DECODER_VMEM_KB, 262144..8388608,
default 1048576 = 1 GiB). Out-of-range values are rejected with exit 3, and a
cap that cannot be applied is an error (the tool fails closed). dpkg-deb runs
single-threaded (--threads-max=1) so the xz decoder fits under the cap.

Verdicts and exit codes:
  match            0  outside (hypervisor) hash == inside hash == package
                      file hash, and the archive signature check verified the
                      .deb (or --no-archive-check was given). Trust:
                      outside-verified.
  match-unverified 4  inside hash == package file hash but there is no
                      independent outside view (trust: self-reported, resting
                      entirely on the target's honesty), OR the outside view
                      agrees but the archive signature is not verified (trust:
                      outside-read-unsigned-package; the .deb is vouched for
                      only by the target's apt metadata).
  mismatch         1  any of the compared hashes differ
  package-unknown  2  not owned by a package, diverted, version not in the
                      archive, or unsupported (third-party) origin
  error            3  usage error, ssh failure, non-canonical path, download or
                      metadata failure (.deb sha256 != target apt SHA256, or
                      .deb control fields != claimed package), outside file
                      is not a regular file or its read is incomplete, the
                      package member is a link, or the archive signature check
                      failed (bad signature, expired or tampered signed index,
                      or the signed index disagrees with the target). A mismatch already established
                      by the inside hash is reported as mismatch even when the
                      outside view then fails.

Note: archive_signature is "verified" only when the runner itself checked the
archive's GPG-signed InRelease (gpgv, at least one valid signature and no
bad, expired or revoked one; stricter than apt, see below), the index hash and size
from it, and found the .deb SHA256 and Filename in the signed index; a
compromised target cannot forge that binding. Unless --no-archive-check is
given, a final "match" requires "verified"; any other archive state downgrades
an outside-verified match to match-unverified (exit 4). "not-verified" means
the check could not run or could not vouch for this version (for example the
index is stale or the version was superseded). Compared with apt the policy is
stricter: besides bad signatures it rejects any signature error other than a
missing key, and it enforces a maximum signed-index age. "failed" (verdict
error, exit 3) means the signed data contradicts the target, the signature is
bad or the target supplied malformed suite data; an already established
mismatch still reports as mismatch. The outside
view stays the only independent evidence about the live file. A block-device
read of a running container can lag the page cache.
EOF
}

HOST="" FPATH="" PVE_HOST="" CTID="" FORMAT="json" MIRROR="" INSIDE_VIA_PCT=0 KEYRING="" ARCHIVE_ENABLED=1 MAX_INDEX_AGE_DAYS=14 DOWNGRADED=0

# ---- state used for output ----
RESOLVED="" DPKG_PATH="" INSIDE_SIZE="" MEMBER_SIZE="" PKG="" VERSION="" ARCH="" ORIGIN="" DEB_URL="" DEB_SHA="" DEB_META_MATCH="null"
APT_SHA="" SHA_INSIDE="" SHA_EXTRACTED="" SHA_OUTSIDE="" OUTSIDE_REASON="" VERDICT="" REASON=""
WORK=""
# archive check state (see archive_check)
ARCHIVE_STATE="not-verified"
ARCHIVE_REASON="archive check not reached (an earlier stage ended the run)"
ARCHIVE_BAD_STATUS="" ORIGIN_IDXARCH="" ARCHIVE_SUITE="" ARCHIVE_COMPONENT="" ARCHIVE_INDEX="" ARCHIVE_FPRS=""
USED_SNAPSHOT=0
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
PV_DECODER_TIMEOUT="${PV_DECODER_TIMEOUT:-120}"
PV_DECODER_VMEM_KB="${PV_DECODER_VMEM_KB:-1048576}"

cleanup() {
  if [[ -n "${WORK}" && -d "${WORK}" ]]; then
    rm -rf -- "${WORK}"
  fi
}
trap cleanup EXIT

fail_usage() {
  echo "package-verify: $*" >&2
  echo "Try '$(basename "$0") --help'." >&2
  exit 3
}

# ---- validation (before any remote use) ----
valid_path() {
  local p="$1"
  [[ "$p" =~ ^/[A-Za-z0-9._+/-]*$ ]] || return 1
  [[ "$p" != *..* ]] || return 1
  [[ "$p" != */ ]] || return 1
  return 0
}
valid_target() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@:-]*$ ]]; }
valid_pkg() { [[ "$1" =~ ^[a-z0-9][a-z0-9.+-]*(:[a-z0-9-]+)?$ ]]; }
valid_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
valid_mirror() { [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~+/-]*)?$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || fail_usage "--host needs a value"; HOST="$2"; shift 2 ;;
    --path) [[ $# -ge 2 ]] || fail_usage "--path needs a value"; FPATH="$2"; shift 2 ;;
    --pve-host) [[ $# -ge 2 ]] || fail_usage "--pve-host needs a value"; PVE_HOST="$2"; shift 2 ;;
    --ctid) [[ $# -ge 2 ]] || fail_usage "--ctid needs a value"; CTID="$2"; shift 2 ;;
    --inside-via-pct) INSIDE_VIA_PCT=1; shift ;;
    --format) [[ $# -ge 2 ]] || fail_usage "--format needs a value"; FORMAT="$2"; shift 2 ;;
    --mirror) [[ $# -ge 2 ]] || fail_usage "--mirror needs a value"; MIRROR="$2"; shift 2 ;;
    --keyring) [[ $# -ge 2 ]] || fail_usage "--keyring needs a value"; KEYRING="$2"; shift 2 ;;
    --no-archive-check) ARCHIVE_ENABLED=0; shift ;;
    --max-index-age-days) [[ $# -ge 2 ]] || fail_usage "--max-index-age-days needs a value"; MAX_INDEX_AGE_DAYS="$2"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    --version) echo "package-verify ${TOOL_VERSION}"; exit 0 ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$FPATH" ]] || fail_usage "--path is required"
valid_path "$FPATH" || fail_usage "--path must be absolute, match [A-Za-z0-9._+/-], and contain no '..'"
case "$FORMAT" in json | md) ;; *) fail_usage "--format must be json or md" ;; esac
if [[ -n "$HOST" ]]; then valid_target "$HOST" || fail_usage "--host has invalid characters"; fi
if [[ -n "$PVE_HOST" ]]; then valid_target "$PVE_HOST" || fail_usage "--pve-host has invalid characters"; fi
if [[ -n "$CTID" ]]; then [[ "$CTID" =~ ^[0-9]+$ ]] || fail_usage "--ctid must be digits"; fi
if [[ -n "$CTID" && -z "$PVE_HOST" ]] || [[ -n "$PVE_HOST" && -z "$CTID" ]]; then
  fail_usage "--pve-host and --ctid must be given together"
fi
if [[ "$INSIDE_VIA_PCT" -eq 1 ]]; then
  [[ -n "$PVE_HOST" ]] || fail_usage "--inside-via-pct needs --pve-host and --ctid"
else
  [[ -n "$HOST" ]] || fail_usage "--host is required"
fi
[[ "$MAX_INDEX_AGE_DAYS" =~ ^[0-9]{1,3}$ ]] && (( 10#$MAX_INDEX_AGE_DAYS >= 1 && 10#$MAX_INDEX_AGE_DAYS <= 365 )) || fail_usage "--max-index-age-days must be an integer from 1 to 365"
MAX_INDEX_AGE_DAYS=$((10#$MAX_INDEX_AGE_DAYS))
if [[ -n "$KEYRING" ]]; then valid_path "$KEYRING" || fail_usage "--keyring must be an absolute path (characters A-Z a-z 0-9 . _ + / -)"; fi
if [[ -n "$MIRROR" ]]; then valid_mirror "$MIRROR" || fail_usage "--mirror must be an https URL"; MIRROR="${MIRROR%/}"; fi
[[ "$PV_DECODER_TIMEOUT" =~ ^[0-9]{1,7}$ && "$PV_DECODER_VMEM_KB" =~ ^[0-9]{1,9}$ ]] || fail_usage "PV_DECODER_TIMEOUT and PV_DECODER_VMEM_KB must be decimal digits"
PV_DECODER_TIMEOUT=$((10#$PV_DECODER_TIMEOUT))
PV_DECODER_VMEM_KB=$((10#$PV_DECODER_VMEM_KB))
(( PV_DECODER_TIMEOUT >= 1 && PV_DECODER_TIMEOUT <= 3600 )) || fail_usage "PV_DECODER_TIMEOUT must be between 1 and 3600 seconds"
(( PV_DECODER_VMEM_KB >= 262144 && PV_DECODER_VMEM_KB <= 8388608 )) || fail_usage "PV_DECODER_VMEM_KB must be between 262144 and 8388608"
# Fail closed: refuse to run at all if the memory cap cannot be applied.
( ulimit -v "$PV_DECODER_VMEM_KB" ) 2>/dev/null || fail_usage "cannot apply the decoder memory cap (ulimit -v ${PV_DECODER_VMEM_KB}); refusing to run uncapped"

# ---- dependency preflight (before any output that assumes jq) ----
missing=""
for dep in jq curl dpkg-deb tar ssh sha256sum timeout; do
  command -v "$dep" >/dev/null 2>&1 || missing+=" ${dep}"
done
[[ -z "$missing" ]] || fail_usage "missing required command(s):${missing}"

# ---- output ----
emit_json() {
  local outside_json="null" outside_reason_json="null"
  [[ -n "$SHA_OUTSIDE" ]] && outside_json="\"${SHA_OUTSIDE}\""
  [[ -n "$OUTSIDE_REASON" ]] && outside_reason_json="$(jq -n --arg r "$OUTSIDE_REASON" '$r')"
  jq -n \
    --arg tool_version "$TOOL_VERSION" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "${HOST:-${PVE_HOST}/ct${CTID}}" \
    --arg path "$FPATH" \
    --arg resolved "$RESOLVED" \
    --arg dpkg_path "$DPKG_PATH" \
    --arg pve_host "$PVE_HOST" \
    --arg ctid "$CTID" \
    --arg package "$PKG" \
    --arg version "$VERSION" \
    --arg arch "$ARCH" \
    --arg origin "$ORIGIN" \
    --arg deb_url "$DEB_URL" \
    --arg deb_sha256 "$DEB_SHA" \
    --arg apt_sha256 "$APT_SHA" \
    --argjson deb_matches_apt "$DEB_META_MATCH" \
    --arg inside "$SHA_INSIDE" \
    --arg extracted "$SHA_EXTRACTED" \
    --argjson outside "$outside_json" \
    --argjson outside_reason "$outside_reason_json" \
    --arg verdict "$VERDICT" \
    --arg trust "$(trust_level)" \
    --arg reason "$REASON" \
    --arg arch_state "$ARCHIVE_STATE" \
    --arg arch_reason "$ARCHIVE_REASON" \
    --arg arch_suite "$ARCHIVE_SUITE" \
    --arg arch_comp "$ARCHIVE_COMPONENT" \
    --arg arch_index "$ARCHIVE_INDEX" \
    --arg arch_fprs "$ARCHIVE_FPRS" \
    --arg arch_note "$(archive_note)" \
    '
    def nn: if . == "" then null else . end;
    {
      tool: "package-verify",
      tool_version: $tool_version,
      timestamp_utc: $timestamp,
      inputs: {host: $host, path: $path, pve_host: ($pve_host | nn), ctid: ($ctid | nn)},
      resolved_path: ($resolved | nn),
      dpkg_path: ($dpkg_path | nn),
      package: ($package | nn),
      version: ($version | nn),
      arch: ($arch | nn),
      origin: ($origin | nn),
      deb_url: ($deb_url | nn),
      deb_sha256: ($deb_sha256 | nn),
      apt_sha256: ($apt_sha256 | nn),
      deb_matches_apt_metadata: $deb_matches_apt,
      sha256_inside: ($inside | nn),
      sha256_extracted: ($extracted | nn),
      sha256_outside: $outside,
      sha256_outside_reason: $outside_reason,
      verdict: $verdict,
      trust: $trust,
      reason: ($reason | nn),
      trust_note: "outside-verified means an independent hypervisor read of the caller-supplied path agrees with the package file. self-reported means every fact came from the target itself and rests entirely on the target honesty. outside-read-unsigned-package means the outside read agrees with the package file but the archive signature was not verified, so the .deb rests on the target apt metadata.",
      archive_signature: $arch_state,
      archive_signature_detail: {
        suite: ($arch_suite | nn),
        component: ($arch_comp | nn),
        index: ($arch_index | nn),
        signer_fingerprints: ($arch_fprs | split(" ") | map(select(. != ""))),
        reason: ($arch_reason | nn)
      },
      archive_signature_note: $arch_note,
      outside_note: "A block-device read of a running container can lag the page cache."
    }'
}

archive_note() {
  case "$ARCHIVE_STATE" in
    verified) echo "The runner verified the archive GPG signature on InRelease, the index hash and size, and found this .deb SHA256 and Filename in the signed index, so the binding to the .deb does not depend on the target's apt metadata." ;;
    failed) echo "The archive signature check failed: the signed archive data is bad, expired, or contradicts the target's apt metadata. Do not trust the .deb binding." ;;
    *) echo "The .deb is bound only to the SHA256 the target reports from its apt lists, which a compromised target can forge, because the independent archive signature check did not complete (see archive_signature_detail.reason)." ;;
  esac
}

# Markdown rendering of target-controlled text. Keep printable ASCII only
# (drops control characters, newlines, and non-ASCII look-alikes), truncate,
# then backslash-escape Markdown and HTML significant characters.
md_clean() { # md_clean <text> [max-length]  (no escaping)
  printf '%s' "$1" | LC_ALL=C tr -cd '\040-\176' | head -c "${2:-200}"
}
md_esc() { # md_esc <text> [max-length]
  md_clean "$1" "${2:-200}" | sed -e 's/[][\\`*_|<>&#~!(){}]/\\&/g'
}
# Code-span variant: no escaping is possible inside backticks, so drop the
# characters that could end the span or the table cell instead.
md_code() { # md_code <text> [max-length]
  md_clean "$1" "${2:-200}" | tr -d '`|'
}

emit_md() {
  local outside="${SHA_OUTSIDE:-n/a}" host_label path_cell
  host_label="${HOST:-${PVE_HOST}/ct${CTID}}"
  [[ -z "$SHA_OUTSIDE" && -n "$OUTSIDE_REASON" ]] && outside="n/a ($(md_esc "$OUTSIDE_REASON"))"
  path_cell="\`$(md_code "$FPATH")\`"
  [[ -n "$RESOLVED" && "$RESOLVED" != "$FPATH" ]] && path_cell+=" -> \`$(md_code "$RESOLVED")\`"
  printf '**package-verify %s** | verdict: **%s** | trust: **%s**' "$TOOL_VERSION" "$(md_esc "$VERDICT")" "$(trust_level)"
  [[ -n "$REASON" ]] && printf ' (%s)' "$(md_esc "$REASON")"
  printf '\n\n'
  cat <<EOF
| Field | Value |
| --- | --- |
| Host | \`$(md_code "$host_label")\` |
| Path | ${path_cell} |
| Package | \`$(md_code "${PKG:-n/a}")\` $(md_esc "${VERSION:-}") $(md_esc "${ARCH:-}") |
| Origin | $(md_esc "${ORIGIN:-n/a}") |
| .deb | $(md_esc "${DEB_URL:-n/a}") |
| .deb sha256 | \`$(md_code "${DEB_SHA:-n/a}" 64)\` (matches target apt metadata: $(md_esc "${DEB_META_MATCH}")) |
| sha256 inside | \`$(md_code "${SHA_INSIDE:-n/a}" 64)\` |
| sha256 package file | \`$(md_code "${SHA_EXTRACTED:-n/a}" 64)\` |
| sha256 outside | ${outside} |
| Checked (UTC) | $(date -u +%Y-%m-%dT%H:%M:%SZ) |

Trust: outside-verified means an independent hypervisor read of the caller-supplied path agrees with the package file; self-reported rests entirely on the target's honesty; outside-read-unsigned-package means the outside read agrees with the package file but the .deb is vouched for only by the target's apt metadata. Archive signature: $(md_esc "$ARCHIVE_STATE") ($(md_esc "$ARCHIVE_REASON" 300)$([[ -n "$ARCHIVE_FPRS" ]] && printf '; signer %s' "$(md_esc "$ARCHIVE_FPRS" 200)")). $(md_esc "$(archive_note)" 400) A block-device read of a running container can lag the page cache.
EOF
}

trust_level() {
  if [[ "$DOWNGRADED" -eq 1 ]]; then echo "outside-read-unsigned-package"
  elif [[ -n "$SHA_OUTSIDE" ]]; then echo "outside-verified"; else echo "self-reported"; fi
}

finish() {
  VERDICT="$1"
  REASON="${2:-}"
  # Precedence: mismatch always wins. Otherwise a failed archive check makes the
  # verdict error, and an error that is already being reported also names it.
  if [[ "$ARCHIVE_STATE" == "failed" && "$VERDICT" != "mismatch" ]]; then
    if [[ "$VERDICT" == "error" ]]; then
      REASON="${REASON:+${REASON}; }archive signature check failed: ${ARCHIVE_REASON}"
    else
      REASON="archive signature check failed: ${ARCHIVE_REASON} (the result would otherwise be ${VERDICT})"
      VERDICT="error"
    fi
  fi
  if [[ "$FORMAT" == "md" ]]; then emit_md; else emit_json; fi
  case "$VERDICT" in
    match) exit 0 ;;
    mismatch) exit 1 ;;
    package-unknown) exit 2 ;;
    match-unverified) exit 4 ;;
    *) exit 3 ;;
  esac
}

# ---- remote execution (scripts go over stdin; arguments validated + quoted) ----
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)

# run_inside <script-file> <arg>...   (script text on stdin of ssh)
run_inside() {
  local script="$1"
  shift
  local q="" a
  for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  if [[ "$INSIDE_VIA_PCT" -eq 1 ]]; then
    ssh "${SSH_OPTS[@]}" -- "$PVE_HOST" "pct exec $(printf '%q' "$CTID") -- sh -s --${q}" <<<"$script"
  else
    ssh "${SSH_OPTS[@]}" -- "$HOST" "sh -s --${q}" <<<"$script"
  fi
}

run_pve() {
  local script="$1"
  shift
  local q="" a
  for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  ssh "${SSH_OPTS[@]}" -- "$PVE_HOST" "bash -s --${q}" <<<"$script"
}

# Run a package decoder or parser stage (dpkg-deb, tar, the listing filter) on
# untrusted archive data with a wall clock limit and a virtual memory cap, so a
# decompression bomb or an oversized record cannot exhaust the runner. Used in
# pipelines, i.e. already in its own subshell. Fails closed: if the cap cannot
# be applied the stage exits 3 instead of running uncapped.
decoder() {
  if ! ulimit -v "$PV_DECODER_VMEM_KB" 2>/dev/null; then
    echo "package-verify: cannot apply the decoder memory cap" >&2
    exit 3
  fi
  exec timeout -k 5 "$PV_DECODER_TIMEOUT" "$@"
}

section() { # section <name> <data>
  awk -v s="$1" '$0 == "@@" s {f=1; next} /^@@/ {f=0} f' <<<"$2"
}

# shellcheck disable=SC2016  # remote script, expansion happens on the target
OWNERSHIP_SCRIPT='# pv:ownership
p=$1
r=$(readlink -f -- "$p") || { echo "@@error"; echo "readlink failed"; exit 0; }
if [ ! -f "$r" ]; then echo "@@error"; echo "not a regular file: $r"; exit 0; fi
echo "@@resolved"; echo "$r"
echo "@@owner"
o=$(dpkg -S -- "$r" 2>/dev/null | grep -v "^diversion by") || true
via_alias=0
alias_path=""
alias_real=""
if [ -z "$o" ]; then
  # usrmerge: dpkg may register /bin/x for a file that lives at /usr/bin/x.
  case "$r" in
    /usr/bin/*|/usr/sbin/*|/usr/lib/*|/usr/lib32/*|/usr/lib64/*|/usr/libx32/*) alt=${r#/usr} ;;
    /bin/*|/sbin/*|/lib/*|/lib32/*|/lib64/*|/libx32/*) alt=/usr$r ;;
    *) alt="" ;;
  esac
  if [ -n "$alt" ]; then
    # Accept alias ownership only when the alias really resolves to the file.
    alias_real=$(readlink -f -- "$alt" 2>/dev/null) || alias_real=""
    if [ "$alias_real" = "$r" ]; then
      o=$(dpkg -S -- "$alt" 2>/dev/null | grep -v "^diversion by") || true
      if [ -n "$o" ]; then via_alias=1; alias_path=$alt; fi
    fi
  fi
fi
printf "%s\n" "$o"
echo "@@divert"
echo "truename=$(dpkg-divert --truename "$r" 2>/dev/null)"
echo "listpackage=$(dpkg-divert --listpackage "$r" 2>/dev/null)"
if [ "$via_alias" = 1 ]; then
  echo "alias_truename=$(dpkg-divert --truename "$alias_path" 2>/dev/null)"
  echo "alias_listpackage=$(dpkg-divert --listpackage "$alias_path" 2>/dev/null)"
  echo "@@alias"; echo "$alias_path"; echo "$alias_real"
fi
echo "@@size"; wc -c < "$r" | tr -d " "
echo "@@sha256"
sha256sum -- "$r" | cut -d" " -f1
echo "@@end"
'

# shellcheck disable=SC2016
META_SCRIPT='# pv:meta
pkg=$1
name=${pkg%%:*}
ver=$(dpkg-query -W -f="\${Version}" "$pkg" 2>/dev/null) || ver=""
arch=$(dpkg-query -W -f="\${Architecture}" "$pkg" 2>/dev/null) || arch=""
echo "@@query"; echo "$ver"; echo "$arch"
echo "@@show"
if [ -n "$ver" ] && [ -n "$arch" ]; then
  apt-cache show "$name:$arch=$ver" 2>/dev/null | awk "/^\$/ {if (n) exit} /^(Filename|SHA256|Version|Architecture): / {print; n=1}"
fi
echo "@@policy"
apt-cache policy "$name:$arch" 2>/dev/null
echo "@@end"
'

# shellcheck disable=SC2016
OUTSIDE_SCRIPT='# pv:outside
# Runs under bash with pipefail: a timed-out or failed debugfs read must not
# yield a valid-looking hash of partial or empty input.
set -o pipefail
ctid=$1
f=$2
line=$(pct config "$ctid" 2>/dev/null | grep "^rootfs: ") || { echo "@@error"; echo "no rootfs in pct config"; exit 0; }
volid=${line#rootfs: }
volid=${volid%%,*}
dev=$(pvesm path "$volid" 2>/dev/null) || { echo "@@error"; echo "pvesm path failed"; exit 0; }
echo "@@kind"
if [ -b "$dev" ]; then
  echo "block"
  echo "@@type"; timeout 60 debugfs -R "stat $f" "$dev" 2>/dev/null | sed -n "s/^.*Type: *\([a-z]*\).*/\1/p" | head -n 1
  echo "@@size"; timeout 60 debugfs -R "stat $f" "$dev" 2>/dev/null | sed -n "s/^.*Size: \([0-9][0-9]*\).*/\1/p" | head -n 1
  # One read feeds both the hash and the byte count, so a partial read cannot
  # pair a hash with the count of a different, complete read. The command
  # substitution only returns after the counter (which holds fd 3, a copy of
  # the substitution pipe) has finished, so both values are always complete.
  res=$({
    timeout 300 debugfs -R "cat $f" "$dev" 2>/dev/null \
      | tee >(wc -c | sed "s/^/n=/" >&3) \
      | sha256sum | cut -d" " -f1 | sed "s/^/h=/"
    echo "rc=${PIPESTATUS[*]}" >&3
  } 3>&1)
  case "$res" in *"rc=0 0 0 0 0"*) ;; *) echo "@@error"; echo "debugfs read failed or timed out"; exit 0 ;; esac
  h=$(printf "%s\n" "$res" | sed -n "s/^h=//p" | head -n 1)
  n=$(printf "%s\n" "$res" | sed -n "s/^n=//p" | tr -d " " | head -n 1)
  echo "@@sha256"; echo "$h"
  echo "@@bytes"; echo "$n"
elif [ -d "$dev" ]; then
  echo "dir"
else
  echo "other"
fi
echo "@@end"
'

# ---- 1. inside: ownership + live hash ----
if ! own_out="$(run_inside "$OWNERSHIP_SCRIPT" "$FPATH" 2>/dev/null)"; then
  finish error "ssh to target failed (ownership query)"
fi
[[ "$own_out" == *"@@end"* || "$own_out" == *"@@error"* ]] || finish error "incomplete response from target (ownership query)"
if [[ "$own_out" == *"@@error"* ]]; then
  finish error "target: $(section error "$own_out" | head -n 1)"
fi

RESOLVED="$(section resolved "$own_out" | head -n 1)"
valid_path "$RESOLVED" || finish error "target returned an unsafe resolved path"
if [[ "$RESOLVED" != "$FPATH" ]]; then
  finish error "pass the canonical path (target resolves it to ${RESOLVED})"
fi
SHA_INSIDE="$(section sha256 "$own_out" | head -n 1)"
valid_sha "$SHA_INSIDE" || finish error "target returned an invalid sha256 for the live file"
INSIDE_SIZE="$(section size "$own_out" | head -n 1)"
[[ "$INSIDE_SIZE" =~ ^[0-9]{1,15}$ ]] || finish error "target returned an invalid size for the live file"
if [[ "$SHA_INSIDE" == "$EMPTY_SHA" && "$INSIDE_SIZE" != "0" ]]; then
  finish error "live file hash is the empty-input hash but its size is ${INSIDE_SIZE} bytes; the read failed or was truncated"
fi

divert_true="$(section divert "$own_out" | sed -n 's/^truename=//p' | head -n 1)"
divert_pkg="$(section divert "$own_out" | sed -n 's/^listpackage=//p' | head -n 1)"
if [[ -n "$divert_pkg" || ( -n "$divert_true" && "$divert_true" != "$RESOLVED" ) ]]; then
  finish package-unknown "path is subject to a dpkg diversion (${divert_pkg:-unknown}); the owning package ships a different file at this path"
fi

owner_line="$(section owner "$own_out" | head -n 1)"
if [[ -z "$owner_line" ]]; then
  finish package-unknown "path is not owned by any installed package (dpkg -S found nothing)"
fi
PKG="${owner_line%%: *}"
PKG="${PKG%%,*}"
PKG="${PKG// /}"
valid_pkg "$PKG" || finish error "target returned an unsafe package name"

# The path dpkg registered: the canonical path itself or its usrmerge alias
# (/usr/bin <-> /bin, /usr/sbin <-> /sbin, /usr/lib* <-> /lib*). Anything else
# from the target is rejected. The package member uses the dpkg path; the
# inside hash and the outside view keep using the canonical path.
usrmerge_alias() { # usrmerge_alias <path> -> prints the alias, or nothing
  case "$1" in
    /usr/bin/* | /usr/sbin/* | /usr/lib/* | /usr/lib32/* | /usr/lib64/* | /usr/libx32/*) printf '%s' "${1#/usr}" ;;
    /bin/* | /sbin/* | /lib/* | /lib32/* | /lib64/* | /libx32/*) printf '/usr%s' "$1" ;;
  esac
}
DPKG_PATH="${owner_line##*: }"
valid_path "$DPKG_PATH" || finish error "target returned an unsafe dpkg path"
if [[ "$DPKG_PATH" != "$FPATH" && "$DPKG_PATH" != "$(usrmerge_alias "$FPATH")" ]]; then
  finish error "dpkg registers this file under an unrelated path (${DPKG_PATH}); refusing to guess"
fi
if [[ "$DPKG_PATH" != "$FPATH" ]]; then
  # Alias ownership counts only if the target confirms the alias resolves to
  # the canonical path; otherwise the alias is ignored (not owned). A
  # diversion on the alias is treated like one on the canonical path.
  alias_seen="$(section alias "$own_out" | sed -n '1p')"
  alias_real="$(section alias "$own_out" | sed -n '2p')"
  if [[ "$alias_seen" != "$DPKG_PATH" || "$alias_real" != "$RESOLVED" ]]; then
    finish package-unknown "dpkg registers ${DPKG_PATH}, which does not resolve to ${FPATH} on the target; the alias is ignored, so the path is not owned"
  fi
  alias_divert_true="$(section divert "$own_out" | sed -n 's/^alias_truename=//p' | head -n 1)"
  alias_divert_pkg="$(section divert "$own_out" | sed -n 's/^alias_listpackage=//p' | head -n 1)"
  if [[ -n "$alias_divert_pkg" || ( -n "$alias_divert_true" && "$alias_divert_true" != "$DPKG_PATH" ) ]]; then
    finish package-unknown "alias path ${DPKG_PATH} is subject to a dpkg diversion (${alias_divert_pkg:-unknown}); the owning package ships a different file at this path"
  fi
fi

# ---- 2. inside: version, arch, apt metadata, origin ----
if ! meta_out="$(run_inside "$META_SCRIPT" "$PKG" 2>/dev/null)"; then
  finish error "ssh to target failed (package metadata query)"
fi
[[ "$meta_out" == *"@@end"* ]] || finish error "incomplete response from target (package metadata query)"

VERSION="$(section query "$meta_out" | sed -n '1p')"
ARCH="$(section query "$meta_out" | sed -n '2p')"
[[ "$VERSION" =~ ^[A-Za-z0-9.+:~-]+$ && "$ARCH" =~ ^[a-z0-9-]+$ ]] || finish error "could not read installed version/arch for ${PKG}"
PKG="${PKG%%:*}"

show="$(section show "$meta_out")"
FILENAME="$(sed -n 's/^Filename: //p' <<<"$show" | head -n 1)"
APT_SHA="$(sed -n 's/^SHA256: //p' <<<"$show" | head -n 1)"
if [[ -z "$FILENAME" || -z "$APT_SHA" ]]; then
  finish package-unknown "apt lists on the target have no entry for ${PKG}=${VERSION} (version no longer offered or third-party/local install)"
fi
[[ "$FILENAME" =~ ^[A-Za-z0-9._+~/-]+\.deb$ && "$FILENAME" != *..* && "$FILENAME" != /* ]] || finish error "apt metadata has an unsafe Filename"
valid_sha "$APT_SHA" || finish error "apt metadata has an invalid SHA256"

policy="$(section policy "$meta_out")"
# First real source (non /var/lib/dpkg/status) of the installed version.
origin_line="$(awk -v v="$VERSION" '
  { line=$0; sub(/^ \*\*\* /, "     ", line); n=split(line, f, " ") }
  n == 2 && f[1] == v && f[2] ~ /^[0-9]+$/ { in_v=1; next }
  in_v && n == 2 && f[2] ~ /^[0-9]+$/ { in_v=0 }
  in_v && n >= 2 && f[2] ~ /^https?:\/\// { print f[2], f[3], f[4]; exit }
' <<<"$policy")"
read -r ORIGIN_URL ORIGIN_SUITE ORIGIN_IDXARCH <<<"$origin_line"
ORIGIN_URL="${ORIGIN_URL%/}"
if [[ -z "$MIRROR" ]]; then
  if [[ -z "$ORIGIN_URL" ]]; then
    finish package-unknown "installed version of ${PKG} has no apt archive origin (local or third-party install)"
  fi
  if [[ "$ORIGIN_URL" =~ ^https?://((deb|ftp|security)\.debian\.org|([a-z]{2}\.)?archive\.ubuntu\.com|security\.ubuntu\.com|ftp\.[a-z]{2}\.debian\.org)(/[A-Za-z0-9._/+-]*)?$ ]]; then
    MIRROR="https://${ORIGIN_URL#*://}"
  else
    ORIGIN="${ORIGIN_URL} ${ORIGIN_SUITE}"
    finish package-unknown "unsupported apt origin for ${PKG} (not a Debian or Ubuntu archive); pass --mirror to override"
  fi
fi
ORIGIN="${ORIGIN_URL:-$MIRROR} ${ORIGIN_SUITE:-}"
ORIGIN="${ORIGIN% }"
DEB_URL="${MIRROR}/${FILENAME}"

# ---- 3. runner: download + stream-hash one member (untrusted data, never executed) ----
WORK="$(mktemp -d)" || finish error "mktemp failed"
DEB="${WORK}/package.deb"

fetch() { # fetch <url> <out> [max-bytes] -> prints http code
  curl -sSL --proto '=https' --proto-redir '=https' --max-redirs 5 --max-time 300 --max-filesize "${3:-209715200}" \
    -o "$2" -w '%{http_code}' -- "$1" 2>/dev/null || true
}
net_failure() { [[ -z "$1" || "$1" == 000 || "$1" == 5?? ]]; } # no response, or a server error

# ---- archive signature check (independent of the target) ----
# Binds the downloaded .deb to the archive's GPG-signed index, so a target that
# forges its apt metadata cannot forge this. States: verified, not-verified
# (no verdict change), failed (verdict becomes error unless a mismatch is
# already established; see the verdict step). Only the plaintext written by
# gpgv --output is ever read after the signature check, never the raw InRelease.

arch_done() { ARCHIVE_STATE="$1"; ARCHIVE_REASON="$2"; }

archive_check() {
  local suite comp idx_arch host kr base ir_code
  local gpgv_dir status_file plain ir_file st line bad=0 valid=0 fprs=""
  local until_raw until_ts by_hash want hash size idx_path idx_file idx_code idx_url
  local got_size got_hash stanza_out sf ss decomp ext r1 r2 r3

  if [[ "$ARCHIVE_ENABLED" -eq 0 ]]; then
    arch_done not-verified "disabled by --no-archive-check"; return 0
  fi
  if [[ "$USED_SNAPSHOT" -eq 1 ]]; then
    arch_done not-verified "the .deb came from snapshot.debian.org (version rotated out of the current archive index), so the current signed index cannot vouch for it"; return 0
  fi
  command -v gpgv >/dev/null 2>&1 || { arch_done not-verified "gpgv is not installed on the runner"; return 0; }

  base="${ORIGIN_SUITE%%/*}"; comp=""
  [[ "$ORIGIN_SUITE" == */* ]] && comp="${ORIGIN_SUITE#*/}"
  suite="$base"; idx_arch="$ORIGIN_IDXARCH"
  if [[ -z "$suite" || -z "$comp" || -z "$idx_arch" ]]; then
    arch_done not-verified "the target's apt policy did not report suite, component and architecture for ${PKG}"; return 0
  fi
  if [[ ! "$suite" =~ ^[a-z0-9][a-z0-9.-]*$ || ! "$comp" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$idx_arch" =~ ^[a-z0-9-]+$ ]]; then
    arch_done failed "suite, component or architecture from the target's apt policy is malformed; refusing to use target-controlled data in a URL"; return 0
  fi
  ARCHIVE_SUITE="$suite"; ARCHIVE_COMPONENT="$comp"

  kr="$KEYRING"
  if [[ -z "$kr" ]]; then
    host="${MIRROR#https://}"; host="${host%%[/:]*}"
    if [[ "$host" =~ ^(deb|ftp|security|ftp\.[a-z]{2})\.debian\.org$ ]]; then
      kr="${PV_DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
    elif [[ "$host" =~ ^(([a-z]{2}\.)?archive|security)\.ubuntu\.com$ ]]; then
      kr="${PV_UBUNTU_KEYRING:-/usr/share/keyrings/ubuntu-archive-keyring.gpg}"
    else
      arch_done not-verified "unknown archive host for ${MIRROR}; pass --keyring to choose the trusted keyring"; return 0
    fi
  fi
  [[ -r "$kr" && -s "$kr" ]] || { arch_done not-verified "keyring ${kr} is missing or unreadable on the runner"; return 0; }

  # InRelease: small, https only, then verified by gpgv before any use.
  ir_file="${WORK}/InRelease"
  ir_code="$(fetch "${MIRROR}/dists/${suite}/InRelease" "$ir_file" 1048576)"
  if [[ "$ir_code" != "200" || ! -s "$ir_file" ]]; then
    arch_done not-verified "could not fetch InRelease for ${suite} (http ${ir_code:-none})"; return 0
  fi
  gpgv_dir="${WORK}/gnupg"; mkdir -m 700 "$gpgv_dir" 2>/dev/null || { arch_done not-verified "could not create a private gpgv home"; return 0; }
  status_file="${WORK}/gpgv.status"; plain="${WORK}/InRelease.plain"
  : >"$status_file"
  # Human text is not parsed; only the machine status lines plus the exit
  # status. gpgv exits 2 when a signature is good but another one cannot be
  # checked (for example Debian signs with several keys and an older keyring
  # knows one), so 0 and 2 are both usable; anything else (a timeout is 124,
  # a kill is 137, a crash is above 128) is not.
  local gpgv_rc=0 nodata=0 errsig_other=0 errsig_nokey=0 f2
  ( decoder gpgv --homedir "$gpgv_dir" --keyring "$kr" --status-fd 3 --output "$plain" "$ir_file" ) 3>"$status_file" >/dev/null 2>&1 || gpgv_rc=$?
  while IFS= read -r line; do
    case "$line" in
      "[GNUPG:] BADSIG "* | "[GNUPG:] EXPKEYSIG "* | "[GNUPG:] REVKEYSIG "* | "[GNUPG:] EXPSIG "*)
        bad=1; st="${line#\[GNUPG:\] }"; st="${st%% *}"
        ARCHIVE_BAD_STATUS="${ARCHIVE_BAD_STATUS:-$st}" ;;
      "[GNUPG:] ERRSIG "*)
        read -r -a f2 <<<"$line"
        # ERRSIG <keyid> <pkalgo> <hashalgo> <class> <time> <rc> <fpr>; rc 9 is a missing key
        if [[ "${f2[7]:-}" == "9" ]]; then errsig_nokey=$((errsig_nokey + 1)); else errsig_other=$((errsig_other + 1)); fi ;;
      "[GNUPG:] NODATA "* | "[GNUPG:] FAILURE "*) nodata=1 ;;
      "[GNUPG:] VALIDSIG "*)
        # fields: [GNUPG:] VALIDSIG <fpr> ... <sig-class> <primary-fpr>
        local -a f; read -r -a f <<<"$line"
        local fpr="${f[11]:-${f[2]:-}}"
        if [[ "$fpr" =~ ^[0-9A-Fa-f]{40}$ || "$fpr" =~ ^[0-9A-Fa-f]{64}$ ]]; then
          valid=$((valid + 1)); fprs+="${fprs:+ }${fpr^^}"
        fi ;;
    esac
  done <"$status_file"
  if [[ "$bad" -eq 1 ]]; then
    arch_done failed "InRelease signature check reported ${ARCHIVE_BAD_STATUS} for ${suite}; the signed index is not trustworthy"; return 0
  fi
  if [[ "$gpgv_rc" != "0" && "$gpgv_rc" != "2" ]]; then
    arch_done not-verified "gpgv exited with status ${gpgv_rc} (killed, timed out or failed); cannot rely on the signature result"; return 0
  fi
  if [[ "$nodata" -eq 1 ]]; then
    arch_done not-verified "gpgv reported NODATA or FAILURE for the InRelease of ${suite}"; return 0
  fi
  if [[ "$errsig_other" -gt 0 ]]; then
    arch_done not-verified "gpgv reported a signature error other than a missing key for the InRelease of ${suite}"; return 0
  fi
  if [[ "$valid" -eq 0 || ! -s "$plain" ]]; then
    arch_done not-verified "no signature from a key in ${kr}; the keyring may be stale"; return 0
  fi
  ARCHIVE_FPRS="$fprs"

  until_raw="$(sed -n 's/^Valid-Until: *//p' "$plain" | head -n 1)"
  if [[ -n "$until_raw" ]]; then
    until_ts="$(LC_ALL=C date -u -d "$until_raw" +%s 2>/dev/null)" || until_ts=""
    if [[ ! "$until_ts" =~ ^[0-9]+$ ]]; then
      arch_done failed "InRelease Valid-Until is not a parseable date"; return 0
    fi
    if (( until_ts < $(date -u +%s) )); then
      arch_done failed "InRelease for ${suite} expired (Valid-Until ${until_raw:0:40}); a stale signed index can hide a replaced package"; return 0
    fi
  fi
  # Debian main InRelease carries no Valid-Until, so freshness comes from the
  # signed Date field: not older than --max-index-age-days, not in the future.
  local date_raw date_ts now_ts
  date_raw="$(sed -n 's/^Date: *//p' "$plain" | head -n 1)"
  date_ts="$(LC_ALL=C date -u -d "$date_raw" +%s 2>/dev/null)" || date_ts=""
  if [[ -z "$date_raw" || ! "$date_ts" =~ ^[0-9]+$ ]]; then
    arch_done not-verified "signed InRelease has a missing or unparseable Date; cannot judge freshness"; return 0
  fi
  now_ts="$(date -u +%s)"
  if (( date_ts > now_ts + 86400 )); then
    arch_done not-verified "runner clock or index date is wrong (signed Date is more than 1 day in the future)"; return 0
  fi
  if (( now_ts - date_ts > MAX_INDEX_AGE_DAYS * 86400 )); then
    arch_done not-verified "signed index is older than ${MAX_INDEX_AGE_DAYS} days"; return 0
  fi
  by_hash=0
  grep -qx 'Acquire-By-Hash: yes' "$plain" && by_hash=1

  # Pick Packages.xz (needs xz) or Packages.gz (needs gzip) from the SHA256 block.
  decomp=""
  for ext in xz gz; do
    if [[ "$ext" == xz ]]; then command -v xz >/dev/null 2>&1 || continue; else command -v gzip >/dev/null 2>&1 || continue; fi
    want="${comp}/binary-${idx_arch}/Packages.${ext}"
    line="$(awk -v w="$want" '/^SHA256:/ {f=1; next} /^[^ ]/ {f=0} f && $3 == w {print $1, $2; exit}' "$plain")"
    if [[ -n "$line" ]]; then decomp="$ext"; break; fi
  done
  if [[ -z "$decomp" ]]; then
    arch_done not-verified "no usable Packages.xz or Packages.gz entry (or xz/gzip missing on the runner) for ${comp}/binary-${idx_arch}"; return 0
  fi
  hash="${line% *}"; size="${line#* }"
  idx_path="dists/${suite}/${comp}/binary-${idx_arch}/Packages.${decomp}"
  ARCHIVE_INDEX="${comp}/binary-${idx_arch}/Packages.${decomp}"
  if ! valid_sha "$hash" || [[ ! "$size" =~ ^[0-9]{1,12}$ ]]; then
    arch_done failed "signed InRelease lists a malformed hash or size for ${ARCHIVE_INDEX}"; return 0
  fi
  if (( size > 134217728 )); then
    arch_done not-verified "signed index ${ARCHIVE_INDEX} is larger than the 128 MiB cap"; return 0
  fi
  if [[ "$by_hash" -eq 1 ]]; then
    idx_url="${MIRROR}/dists/${suite}/${comp}/binary-${idx_arch}/by-hash/SHA256/${hash}"
  else
    idx_url="${MIRROR}/${idx_path}"
  fi
  idx_file="${WORK}/Packages.${decomp}"
  idx_code="$(fetch "$idx_url" "$idx_file" 134217728)"
  if [[ "$idx_code" != "200" || ! -f "$idx_file" ]]; then
    arch_done not-verified "could not fetch ${ARCHIVE_INDEX} (http ${idx_code:-none})"; return 0
  fi
  got_size="$(wc -c <"$idx_file" | tr -d ' ')"
  got_hash="$(sha256sum -- "$idx_file" | cut -d' ' -f1)"
  if [[ "$got_size" != "$size" || "$got_hash" != "$hash" ]]; then
    if [[ "$by_hash" -eq 1 ]]; then
      arch_done failed "downloaded ${ARCHIVE_INDEX} (fetched by hash) does not match the size and SHA256 in the signed InRelease; possible tampering"
    else
      arch_done not-verified "index changed during fetch (mirror mid-sync) or was altered: ${ARCHIVE_INDEX} does not match the signed size and SHA256"
    fi
    return 0
  fi

  # Stream-parse the index for the exact package/version/architecture stanza.
  # Lines are clipped, every stage is time and memory bounded, and the awk
  # program stops after two matches.
  local dec_cmd=(xz -dc -T1)
  [[ "$decomp" == gz ]] && dec_cmd=(gzip -dc)
  # shellcheck disable=SC2016  # awk program
  stanza_out="$(decoder "${dec_cmd[@]}" -- "$idx_file" 2>/dev/null | decoder cut -b 1-4096 | PV_P="$PKG" PV_V="$VERSION" PV_A="$ARCH" decoder awk '
    function flush() {
      if (p == ENVIRON["PV_P"] && v == ENVIRON["PV_V"] && a == ENVIRON["PV_A"]) {
        n++; printf "%s\t%s\n", substr(fn, 1, 512), substr(sh, 1, 64)
        if (n >= 2) exit
      }
      p = v = a = fn = sh = ""
    }
    /^$/ { flush(); next }
    /^Package: / { p = substr($0, 10) }
    /^Version: / { v = substr($0, 10) }
    /^Architecture: / { a = substr($0, 15) }
    /^Filename: / { fn = substr($0, 11) }
    /^SHA256: / { sh = substr($0, 9) }
    END { flush() }
  '; printf '@@rc %s' "${PIPESTATUS[*]}")"
  local rc_all="${stanza_out##*@@rc }"
  stanza_out="${stanza_out%@@rc *}"
  stanza_out="${stanza_out%$'\n'}"
  read -r r1 r2 r3 <<<"$rc_all"
  # The decompressor (r1) and cut (r2) may die of SIGPIPE (141) when awk exits
  # early after two matching stanzas; any other non-zero status from them, and
  # any non-zero awk status (r3), means the parse is not trusted.
  if [[ "$r3" != "0" ]] || { [[ "$r1" != "0" && "$r1" != "141" ]] || [[ "$r2" != "0" && "$r2" != "141" ]]; }; then
    arch_done not-verified "could not parse ${ARCHIVE_INDEX} (decoder failed or timed out)"; return 0
  fi
  if [[ -z "$stanza_out" ]]; then
    arch_done not-verified "${PKG}=${VERSION} (${ARCH}) is not in the current signed index (superseded or rotated out); cannot vouch for it"; return 0
  fi
  if [[ "$stanza_out" == *$'\n'* ]]; then
    arch_done not-verified "the signed index lists ${PKG}=${VERSION} (${ARCH}) more than once; refusing to guess"; return 0
  fi
  IFS=$'\t' read -r sf ss <<<"$stanza_out"
  if [[ "$ss" != "$APT_SHA" || "$sf" != "$FILENAME" ]]; then
    arch_done failed "signed archive index disagrees with the target's apt metadata: possible tampering"; return 0
  fi
  arch_done verified "the .deb SHA256 and Filename match the stanza in the GPG-signed ${ARCHIVE_INDEX}"
}

code="$(fetch "$DEB_URL" "$DEB")"
if [[ "$code" == "404" && "$MIRROR" == *debian.org* ]]; then
  # Version rotated out of the pool: look it up on snapshot.debian.org.
  enc_ver="${VERSION//:/%3A}"
  meta_json="${WORK}/snapshot.json"
  mcode="$(fetch "https://snapshot.debian.org/mr/binary/${PKG}/${enc_ver}/binfiles?fileinfo=1" "$meta_json")"
  if net_failure "$mcode"; then
    finish error "snapshot.debian.org lookup failed (http ${mcode:-none}); cannot tell whether the version exists"
  fi
  if [[ "$mcode" == "200" ]]; then
    snap_hash="$(jq -r --arg a "$ARCH" '[.result[] | select(.architecture == $a) | .hash][0] // empty' "$meta_json" 2>/dev/null || true)"
    if [[ "$snap_hash" =~ ^[0-9a-f]{40,64}$ ]]; then
      DEB_URL="https://snapshot.debian.org/file/${snap_hash}"
      USED_SNAPSHOT=1
      code="$(fetch "$DEB_URL" "$DEB")"
    fi
  fi
  if [[ "$code" != "200" ]]; then
    if net_failure "$code"; then
      finish error "download failed (http ${code:-none}) for ${DEB_URL}"
    fi
    finish package-unknown "${PKG}=${VERSION} is not in the pool or on snapshot.debian.org"
  fi
fi
if net_failure "$code"; then
  finish error "download failed (http ${code:-none}) for ${DEB_URL}"
fi
if [[ "$code" == "404" ]]; then
  finish package-unknown "${PKG}=${VERSION} not found at ${DEB_URL}"
fi
[[ "$code" == "200" && -s "$DEB" ]] || finish error "download failed (http ${code:-none}) for ${DEB_URL}"

DEB_SHA="$(sha256sum -- "$DEB" | cut -d' ' -f1)"
if [[ "$DEB_SHA" != "$APT_SHA" ]]; then
  DEB_META_MATCH="false"
  finish error "downloaded .deb sha256 does not equal the target apt SHA256 (corrupt download, wrong mirror, or tampering); not trusting it"
fi
DEB_META_MATCH="true"

# Independent archive check. Its outcome is only recorded here; the verdict step
# decides precedence (an established mismatch always wins over a failed check).
archive_check

# The archive must be the package the target claimed (name, version, arch).
# Control output is capped at 4 KiB; decoders are time and memory bounded.
ctrl_raw="$(decoder dpkg-deb -f "$DEB" Package Version Architecture 2>/dev/null | head -c 4097; printf '@@rc %s' "${PIPESTATUS[*]}")"
ctrl="${ctrl_raw%@@rc *}"
ctrl_rc="${ctrl_raw##*@@rc }"
[[ "$(printf '%s' "$ctrl" | LC_ALL=C wc -c)" -le 4096 ]] || finish error "dpkg-deb -f output is oversized; not trusting the package"
[[ "$ctrl_rc" == "0 0" ]] || finish error "dpkg-deb -f failed or timed out on the downloaded package"
c_pkg="$(sed -n 's/^Package: //p' <<<"$ctrl" | head -n 1)"
c_ver="$(sed -n 's/^Version: //p' <<<"$ctrl" | head -n 1)"
c_arch="$(sed -n 's/^Architecture: //p' <<<"$ctrl" | head -n 1)"
if [[ "$c_pkg" != "$PKG" || "$c_ver" != "$VERSION" || "$c_arch" != "$ARCH" ]]; then
  finish error "downloaded .deb control fields do not match the target claim (package, version or architecture); not trusting it"
fi

# Locate the member without extracting anything or keeping the listing: the
# tar listing is filtered as a stream for ./<DPKG_PATH> and the reader stops
# after two matches (that already proves "not exactly one"). The early exit
# makes the decoders die of SIGPIPE (141), which is expected only then.
MEMBER=".${DPKG_PATH}"
# Record bounding: tar -tv prints one line per member and a crafted PAX link
# target can make that line enormous. cut (streaming, no line buffer) clips
# every line before awk sees it, and awk emits only bounded fields: type
# char, size, member name (512 bytes max) and link target (256 bytes max).
# Every stage, including the parser, runs under the timeout and memory cap.
# shellcheck disable=SC2016  # awk program, expansion is not wanted
list_raw="$(decoder dpkg-deb --fsys-tarfile --threads-max=1 "$DEB" 2>/dev/null | decoder tar -tvf - 2>/dev/null | decoder cut -b 1-2048 | decoder awk -v m="$MEMBER" '
  { rest=$0; if (!sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", rest)) next
    tgt=""
    if (rest == m) { name=m }
    else if (index(rest, m " -> ") == 1) { name=m; tgt=substr(rest, length(m) + 5) }
    else if (index(rest, m " link to ") == 1) { name=m; tgt=substr(rest, length(m) + 10) }
    else next
    gsub(/\t/, " ", tgt)
    n++; printf "%s\t%s\t%s\t%s\n", substr($0, 1, 1), $3, substr(name, 1, 512), substr(tgt, 1, 256)
    if (n >= 2) exit
  }
'; printf '@@rc %s' "${PIPESTATUS[*]}")"
list_rc="${list_raw##*@@rc }"
members="${list_raw%@@rc *}"
members="${members%$'\n'}"
n_members=0
[[ -z "$members" ]] || n_members="$(wc -l <<<"$members")"
read -r rc_dpkg rc_tar rc_cut rc_awk <<<"$list_rc"
if [[ "$rc_awk" != "0" ]]; then
  finish error "could not list the downloaded package contents"
fi
# 141 (SIGPIPE) is the expected early-exit status only after two matches.
for rc in "$rc_dpkg" "$rc_tar" "$rc_cut"; do
  if [[ "$rc" != "0" && ! ( "$rc" == "141" && "$n_members" -ge 2 ) ]]; then
    finish error "could not list the downloaded package contents (decoder status ${rc}; a timeout or memory cap also lands here)"
  fi
done
if [[ "$n_members" -eq 0 ]]; then
  finish package-unknown "package ${PKG}=${VERSION} does not contain ${DPKG_PATH} (generated at install time)"
fi
if [[ "$n_members" -ne 1 ]]; then
  finish error "package ${PKG}=${VERSION} has more than one entry for ${DPKG_PATH}; refusing to guess"
fi
IFS=$'\t' read -r m_type MEMBER_SIZE _ m_target <<<"$members"
if [[ "$m_type" != "-" ]]; then
  hint=""
  case "$m_type" in
    h | l) t="$m_target" ;;
    *) t="" ;;
  esac
  t="${t#./}"
  t="/$(md_clean "$t" 120)"
  if [[ -n "$t" && "$t" != "/" ]] && valid_path "$t"; then
    hint="; it points at ${t}, verify that path instead"
  fi
  finish error "package ${PKG}=${VERSION} ships ${DPKG_PATH} as a link or special entry, not a regular file${hint}"
fi
[[ "$MEMBER_SIZE" =~ ^[0-9]{1,15}$ ]] || finish error "package listing has an invalid size for ${DPKG_PATH}"
SHA_EXTRACTED="$(decoder dpkg-deb --fsys-tarfile --threads-max=1 "$DEB" 2>/dev/null | decoder tar -xOf - "$MEMBER" 2>/dev/null | sha256sum | cut -d' ' -f1)" \
  || finish error "could not stream the package file out of the archive (decoder failed or timed out)"
valid_sha "$SHA_EXTRACTED" || finish error "could not hash the package file"

# ---- 4. outside view (Proxmox host, read-only, caller-supplied path only) ----
# Failures here do not finish immediately: an established inside mismatch must
# still be reported as a mismatch. They set OUTSIDE_FAIL (also kept as the
# JSON reason) and the verdict step turns them into an error otherwise.
OUTSIDE_FAIL=""
take_outside() {
  local out_raw o_kind o_type o_size o_sha o_bytes
  if ! out_raw="$(run_pve "$OUTSIDE_SCRIPT" "$CTID" "$FPATH" 2>/dev/null)" || [[ "$out_raw" != *"@@end"* && "$out_raw" != *"@@error"* ]]; then
    OUTSIDE_FAIL="outside view requested but unavailable: ssh to the Proxmox host failed or returned an incomplete response"
    return 0
  fi
  if [[ "$out_raw" == *"@@error"* ]]; then
    OUTSIDE_FAIL="outside view requested but unavailable: $(md_clean "$(section error "$out_raw" | head -n 1)" 200)"
    return 0
  fi
  o_kind="$(section kind "$out_raw" | head -n 1)"
  case "$o_kind" in
    block)
      o_type="$(section type "$out_raw" | head -n 1)"
      o_size="$(section size "$out_raw" | head -n 1)"
      o_sha="$(section sha256 "$out_raw" | head -n 1)"
      o_bytes="$(section bytes "$out_raw" | head -n 1)"
      if [[ -z "$o_type" || -z "$o_size" ]]; then
        OUTSIDE_FAIL="outside view requested but the file could not be stat'ed on the volume (missing or read failed)"
      elif [[ "$o_type" != "regular" ]]; then
        OUTSIDE_FAIL="outside view: ${FPATH} is not a regular file on the container volume (type: $(md_clean "$o_type" 20)); pass the canonical path"
      elif ! valid_sha "$o_sha"; then
        OUTSIDE_FAIL="outside view requested but returned no valid sha256"
      elif [[ ! "$o_size" =~ ^[0-9]{1,15}$ || ! "$o_bytes" =~ ^[0-9]{1,15}$ ]]; then
        OUTSIDE_FAIL="outside view returned no valid size or byte count"
      elif [[ "$o_bytes" != "$o_size" ]]; then
        OUTSIDE_FAIL="outside view read ${o_bytes} bytes but the volume reports ${o_size}; the read was incomplete, so its hash is not trusted"
      else
        SHA_OUTSIDE="$o_sha"
        OUTSIDE_SIZE="$o_size"
      fi
      ;;
    dir) OUTSIDE_REASON="unsupported rootfs type (directory-backed); outside view not taken" ;;
    *) OUTSIDE_REASON="unsupported rootfs type (not a block device); outside view not taken" ;;
  esac
}
OUTSIDE_SIZE=""
if [[ -n "$PVE_HOST" && -n "$CTID" ]]; then
  take_outside
  [[ -z "$OUTSIDE_FAIL" ]] || OUTSIDE_REASON="$OUTSIDE_FAIL"
else
  OUTSIDE_REASON="no --pve-host/--ctid given (no independent outside view)"
fi

# ---- 5. verdict ----
# Precedence: a hash mismatch beats any failure of the outside view.
if [[ "$SHA_INSIDE" != "$SHA_EXTRACTED" ]]; then
  note=""
  [[ -z "$OUTSIDE_FAIL" ]] || note="; the outside view also failed: $(md_clean "$OUTSIDE_FAIL" 160)"
  finish mismatch "live file differs from the package file${note}"
fi
if [[ "$INSIDE_SIZE" != "$MEMBER_SIZE" ]]; then
  finish error "live file size (${INSIDE_SIZE}) differs from the package file size (${MEMBER_SIZE}) although the hashes agree; the read is inconsistent"
fi
[[ -z "$OUTSIDE_FAIL" ]] || finish error "$OUTSIDE_FAIL"
if [[ -n "$SHA_OUTSIDE" && "$SHA_OUTSIDE" != "$SHA_EXTRACTED" ]]; then
  finish mismatch "outside read differs from the package file"
fi
# A failed archive check is applied centrally in finish(): it turns any verdict
# except mismatch into error, and it is named in an existing error's reason.
if [[ -n "$SHA_OUTSIDE" && "$OUTSIDE_SIZE" != "$MEMBER_SIZE" ]]; then
  SHA_OUTSIDE=""
  finish error "outside size (${OUTSIDE_SIZE}) differs from the package file size (${MEMBER_SIZE}) although the hashes agree; the read is inconsistent"
fi
if [[ -n "$SHA_OUTSIDE" ]]; then
  # A match (exit 0) needs the archive to have vouched for the .deb, unless the
  # caller opted out with --no-archive-check (v1.3 behavior).
  if [[ "$ARCHIVE_ENABLED" -eq 1 && "$ARCHIVE_STATE" != "verified" ]]; then
    DOWNGRADED=1
    finish match-unverified "archive signature not verified: ${ARCHIVE_REASON}; the outside read agrees with the package file but the .deb is vouched for only by the target's apt metadata"
  fi
  finish match ""
fi
finish match-unverified "no independent outside view: ${OUTSIDE_REASON}; the result is self-reported by the target"
