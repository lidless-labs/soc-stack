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
#       [--format json|md] [--mirror <url>]
#
# Exit codes: 0 match (outside-verified), 1 mismatch, 2 package-unknown,
# 3 error/usage, 4 match-unverified (self-reported only).
set -euo pipefail

TOOL_VERSION="1.1.0"

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
  --help                show this help
  --version             show the tool version

Remote commands (all read-only): readlink, stat, sha256sum, dpkg -S,
dpkg-divert, dpkg-query, apt-cache show/policy. On the Proxmox host: pct config,
pvesm path, debugfs (read-only, no -w). It never mounts or writes.

Verdicts and exit codes:
  match            0  outside (hypervisor) hash == inside hash == package
                      file hash. Trust: outside-verified.
  match-unverified 4  inside hash == package file hash but there is no
                      independent outside view. Trust: self-reported, resting
                      entirely on the target's honesty.
  mismatch         1  any of the compared hashes differ
  package-unknown  2  not owned by a package, diverted, version not in the
                      archive, or unsupported (third-party) origin
  error            3  usage error, ssh failure, non-canonical path, download or
                      metadata failure (.deb sha256 != target apt SHA256, or
                      .deb control fields != claimed package), outside file
                      is not a regular file, or the package member is a link

Note: archive_signature is always "not-verified". Trust in the .deb rests on
the target's apt-verified metadata (SHA256 from its GPG-checked lists), which a
compromised target can forge; only the outside view is independent. Independent
InRelease checking needs a Debian keyring on the runner; this tool never
installs one. A block-device read of a running container can lag the page
cache.
EOF
}

HOST="" FPATH="" PVE_HOST="" CTID="" FORMAT="json" MIRROR="" INSIDE_VIA_PCT=0

# ---- state used for output ----
RESOLVED="" PKG="" VERSION="" ARCH="" ORIGIN="" DEB_URL="" DEB_SHA="" DEB_META_MATCH="null"
APT_SHA="" SHA_INSIDE="" SHA_EXTRACTED="" SHA_OUTSIDE="" OUTSIDE_REASON="" VERDICT="" REASON=""
WORK=""

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
if [[ -n "$MIRROR" ]]; then valid_mirror "$MIRROR" || fail_usage "--mirror must be an https URL"; MIRROR="${MIRROR%/}"; fi

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
    '
    def nn: if . == "" then null else . end;
    {
      tool: "package-verify",
      tool_version: $tool_version,
      timestamp_utc: $timestamp,
      inputs: {host: $host, path: $path, pve_host: ($pve_host | nn), ctid: ($ctid | nn)},
      resolved_path: ($resolved | nn),
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
      trust_note: "outside-verified means an independent hypervisor read of the caller-supplied path agrees with the package file. self-reported means every fact came from the target itself and rests entirely on the target honesty.",
      archive_signature: "not-verified",
      archive_signature_note: "The .deb is bound to the SHA256 the target reports from its apt lists, which a compromised target can forge. Independent InRelease/Packages GPG verification is not done: the runner has no Debian keyring and installing debian-archive-keyring needs the owner approval.",
      outside_note: "A block-device read of a running container can lag the page cache."
    }'
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

Trust: outside-verified means an independent hypervisor read of the caller-supplied path agrees with the package file; self-reported rests entirely on the target's honesty. Archive signature: not-verified (the .deb is bound to the SHA256 the target reports from its apt lists, which a compromised target can forge; InRelease GPG checking is not done because the runner has no Debian keyring). A block-device read of a running container can lag the page cache.
EOF
}

trust_level() {
  if [[ -n "$SHA_OUTSIDE" ]]; then echo "outside-verified"; else echo "self-reported"; fi
}

finish() {
  VERDICT="$1"
  REASON="${2:-}"
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
  ssh "${SSH_OPTS[@]}" -- "$PVE_HOST" "sh -s --${q}" <<<"$script"
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
[ -n "$o" ] || o=$(dpkg -S -- "$p" 2>/dev/null | grep -v "^diversion by") || true
printf "%s\n" "$o"
echo "@@divert"
echo "truename=$(dpkg-divert --truename "$r" 2>/dev/null)"
echo "listpackage=$(dpkg-divert --listpackage "$r" 2>/dev/null)"
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
  echo "@@sha256"; timeout 300 debugfs -R "cat $f" "$dev" 2>/dev/null | sha256sum | cut -d" " -f1
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
  in_v && n >= 2 && f[2] ~ /^https?:\/\// { print f[2], f[3]; exit }
' <<<"$policy")"
ORIGIN_URL="${origin_line%% *}"
ORIGIN_SUITE="${origin_line#* }"
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

fetch() { # fetch <url> <out> -> prints http code
  curl -sSL --proto '=https' --proto-redir '=https' --max-redirs 5 --max-time 300 --max-filesize 209715200 \
    -o "$2" -w '%{http_code}' -- "$1" 2>/dev/null || true
}

code="$(fetch "$DEB_URL" "$DEB")"
if [[ "$code" == "404" && "$MIRROR" == *debian.org* ]]; then
  # Version rotated out of the pool: look it up on snapshot.debian.org.
  enc_ver="${VERSION//:/%3A}"
  meta_json="${WORK}/snapshot.json"
  mcode="$(fetch "https://snapshot.debian.org/mr/binary/${PKG}/${enc_ver}/binfiles?fileinfo=1" "$meta_json")"
  if [[ "$mcode" == "200" ]]; then
    snap_hash="$(jq -r --arg a "$ARCH" '[.result[] | select(.architecture == $a) | .hash][0] // empty' "$meta_json" 2>/dev/null || true)"
    if [[ "$snap_hash" =~ ^[0-9a-f]{40,64}$ ]]; then
      DEB_URL="https://snapshot.debian.org/file/${snap_hash}"
      code="$(fetch "$DEB_URL" "$DEB")"
    fi
  fi
  if [[ "$code" != "200" ]]; then
    finish package-unknown "${PKG}=${VERSION} is not in the pool or on snapshot.debian.org"
  fi
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

# The archive must be the package the target claimed (name, version, arch).
ctrl="$(dpkg-deb -f "$DEB" Package Version Architecture 2>/dev/null)" || finish error "dpkg-deb -f failed on the downloaded package"
c_pkg="$(sed -n 's/^Package: //p' <<<"$ctrl" | head -n 1)"
c_ver="$(sed -n 's/^Version: //p' <<<"$ctrl" | head -n 1)"
c_arch="$(sed -n 's/^Architecture: //p' <<<"$ctrl" | head -n 1)"
if [[ "$c_pkg" != "$PKG" || "$c_ver" != "$VERSION" || "$c_arch" != "$ARCH" ]]; then
  finish error "downloaded .deb control fields do not match the target claim (package, version or architecture); not trusting it"
fi

# Locate the member without extracting anything: exactly one entry named
# ./<FPATH>, and it must be a regular file (tar type '-'), not a link.
MEMBER=".${FPATH}"
listing="$(timeout 120 dpkg-deb --fsys-tarfile "$DEB" 2>/dev/null | timeout 120 tar -tvf - 2>/dev/null)" || finish error "could not list the downloaded package contents"
members="$(awk -v m="$MEMBER" '
  { rest=$0; if (!sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", rest)) next
    if (rest == m || index(rest, m " -> ") == 1 || index(rest, m " link to ") == 1) print substr($0, 1, 1) }
' <<<"$listing")"
n_members=0
[[ -z "$members" ]] || n_members="$(wc -l <<<"$members")"
if [[ "$n_members" -eq 0 ]]; then
  finish package-unknown "package ${PKG}=${VERSION} does not contain ${FPATH} (generated at install time)"
fi
if [[ "$n_members" -ne 1 ]]; then
  finish error "package ${PKG}=${VERSION} has ${n_members} entries for ${FPATH}; refusing to guess"
fi
if [[ "$members" != "-" ]]; then
  finish error "package ${PKG}=${VERSION} ships ${FPATH} as a link or special entry, not a regular file"
fi
SHA_EXTRACTED="$(timeout 300 dpkg-deb --fsys-tarfile "$DEB" 2>/dev/null | timeout 300 tar -xOf - "$MEMBER" 2>/dev/null | sha256sum | cut -d' ' -f1)" \
  || finish error "could not stream the package file out of the archive"
valid_sha "$SHA_EXTRACTED" || finish error "could not hash the package file"

# ---- 4. outside view (Proxmox host, read-only, caller-supplied path only) ----
if [[ -n "$PVE_HOST" && -n "$CTID" ]]; then
  if out_raw="$(run_pve "$OUTSIDE_SCRIPT" "$CTID" "$FPATH" 2>/dev/null)" && [[ "$out_raw" == *"@@end"* || "$out_raw" == *"@@error"* ]]; then
    if [[ "$out_raw" == *"@@error"* ]]; then
      finish error "outside view requested but unavailable: $(section error "$out_raw" | head -n 1)"
    fi
    o_kind="$(section kind "$out_raw" | head -n 1)"
    case "$o_kind" in
      block)
        o_type="$(section type "$out_raw" | head -n 1)"
        o_size="$(section size "$out_raw" | head -n 1)"
        o_sha="$(section sha256 "$out_raw" | head -n 1)"
        if [[ -z "$o_type" || -z "$o_size" ]]; then
          finish error "outside view requested but the file could not be stat'ed on the volume (missing or read failed)"
        fi
        if [[ "$o_type" != "regular" ]]; then
          finish error "outside view: ${FPATH} is not a regular file on the container volume (type: $(md_clean "$o_type" 20)); pass the canonical path"
        fi
        valid_sha "$o_sha" || finish error "outside view requested but returned no valid sha256"
        SHA_OUTSIDE="$o_sha"
        ;;
      dir)
        OUTSIDE_REASON="unsupported rootfs type (directory-backed); outside view not taken"
        ;;
      *)
        OUTSIDE_REASON="unsupported rootfs type (not a block device); outside view not taken"
        ;;
    esac
  else
    finish error "outside view requested but unavailable: ssh to the Proxmox host failed or returned an incomplete response"
  fi
else
  OUTSIDE_REASON="no --pve-host/--ctid given (no independent outside view)"
fi

# ---- 5. verdict ----
if [[ "$SHA_INSIDE" != "$SHA_EXTRACTED" ]]; then
  finish mismatch "live file differs from the package file"
fi
if [[ -n "$SHA_OUTSIDE" && "$SHA_OUTSIDE" != "$SHA_EXTRACTED" ]]; then
  finish mismatch "outside read differs from the package file"
fi
if [[ -n "$SHA_OUTSIDE" ]]; then
  finish match ""
fi
finish match-unverified "no independent outside view: ${OUTSIDE_REASON}; the result is self-reported by the target"
