#!/usr/bin/env bats
# Unit tests for tools/package-verify.sh. ssh, curl, and dpkg-deb are replaced
# by mocks placed first on PATH; nothing touches a real host or the network.

load helpers/load.bash

TOOL="${BATS_TEST_DIRNAME}/../../tools/package-verify.sh"

sha_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

setup() {
  MOCKBIN="${BATS_TEST_TMPDIR}/mockbin"
  MOCKDIR="${BATS_TEST_TMPDIR}/mock"
  RUNTMP="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${MOCKBIN}" "${MOCKDIR}" "${RUNTMP}"
  export PATH="${MOCKBIN}:${PATH}"
  export MOCKDIR
  export TMPDIR="${RUNTMP}"

  DEB_CONTENT="fake-deb-bytes"
  PKGFILE_CONTENT="pristine-binary"
  DEB_SHA="$(sha_of "${DEB_CONTENT}")"
  PKG_SHA="$(sha_of "${PKGFILE_CONTENT}")"
  printf '%s' "${DEB_CONTENT}" >"${MOCKDIR}/deb_content"
  printf '%s' "${PKGFILE_CONTENT}" >"${MOCKDIR}/extract_content"

  write_ownership "${PKG_SHA}"
  write_meta "${DEB_SHA}"
  write_outside "${PKG_SHA}"

  # ssh: pick a canned response by the marker comment in the stdin script.
  cat >"${MOCKBIN}/ssh" <<'MOCK'
#!/usr/bin/env bash
script="$(cat)"
printf '%s\n' "$*" >>"${MOCKDIR}/ssh.log"
case "${script}" in
  *"# pv:ownership"*) marker=ownership ;;
  *"# pv:meta"*) marker=meta ;;
  *"# pv:outside"*) marker=outside ;;
  *) marker=unknown ;;
esac
echo "${marker}" >>"${MOCKDIR}/ssh.markers"
[[ -f "${MOCKDIR}/ssh_fail_${marker}" ]] && exit 255
cat "${MOCKDIR}/resp_${marker}"
MOCK
  cat >"${MOCKBIN}/curl" <<'MOCK'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --max-time | --max-filesize | --proto | --proto-redir | --max-redirs | -w) shift 2 ;;
    --) shift; url="$1"; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "${url}" >>"${MOCKDIR}/curl.log"
case "${url}" in
  *snapshot.debian.org/mr/binary/*)
    printf '{"result":[{"hash":"%s","architecture":"amd64"}]}' "0123456789abcdef0123456789abcdef01234567" >"${out}"
    printf '200' ;;
  *snapshot.debian.org/file/*)
    cp "${MOCKDIR}/deb_content" "${out}"; printf '200' ;;
  *)
    code="$(cat "${MOCKDIR}/pool_code" 2>/dev/null || echo 200)"
    [[ "${code}" == 200 ]] && cp "${MOCKDIR}/deb_content" "${out}"
    printf '%s' "${code}" ;;
esac
MOCK
  cat >"${MOCKBIN}/dpkg-deb" <<'MOCK'
#!/usr/bin/env bash
# Only the read-only modes the tool may use: -f (control fields) and
# --fsys-tarfile (stream the data archive). Anything else fails the test.
echo "$*" >>"${MOCKDIR}/dpkg-deb.log"
case "$1" in
  -f)
    shift 2 # -f <deb>
    for field in "$@"; do
      case "${field}" in
        Package) echo "Package: $(cat "${MOCKDIR}/ctrl_pkg" 2>/dev/null || echo passwd)" ;;
        Version) echo "Version: $(cat "${MOCKDIR}/ctrl_ver" 2>/dev/null || echo 1:4.17.4-2)" ;;
        Architecture) echo "Architecture: $(cat "${MOCKDIR}/ctrl_arch" 2>/dev/null || echo amd64)" ;;
      esac
    done ;;
  --fsys-tarfile)
    d="$(mktemp -d "${MOCKDIR}/tree.XXXXXX")"
    mkdir -p "${d}/usr/bin"
    mode="$(cat "${MOCKDIR}/tar_mode" 2>/dev/null || echo regular)"
    case "${mode}" in
      regular) cp "${MOCKDIR}/extract_content" "${d}/usr/bin/chsh"; members=(./usr/bin/chsh) ;;
      symlink) ln -s /bin/true "${d}/usr/bin/chsh"; members=(./usr/bin/chsh) ;;
      hardlink)
        cp "${MOCKDIR}/extract_content" "${d}/usr/bin/aaa"
        ln "${d}/usr/bin/aaa" "${d}/usr/bin/chsh"
        members=(./usr/bin/aaa ./usr/bin/chsh) ;;
      absent) cp "${MOCKDIR}/extract_content" "${d}/usr/bin/other"; members=(./usr/bin/other) ;;
      dup)
        cp "${MOCKDIR}/extract_content" "${d}/usr/bin/chsh"
        members=(./usr/bin/chsh ./usr/bin/chsh) ;;
    esac
    tar -cf - -C "${d}" "${members[@]}"
    rm -rf "${d}" ;;
  *) echo "unexpected dpkg-deb mode: $1" >&2; exit 2 ;;
esac
MOCK
  chmod +x "${MOCKBIN}/ssh" "${MOCKBIN}/curl" "${MOCKBIN}/dpkg-deb"
}

write_ownership() { # <live sha>
  cat >"${MOCKDIR}/resp_ownership" <<EOF
@@resolved
/usr/bin/chsh
@@owner
passwd: /usr/bin/chsh
@@divert
truename=/usr/bin/chsh
listpackage=
@@sha256
$1
@@end
EOF
}

write_meta() { # <apt sha256>
  cat >"${MOCKDIR}/resp_meta" <<EOF
@@query
1:4.17.4-2
amd64
@@show
Version: 1:4.17.4-2
Architecture: amd64
Filename: pool/main/s/shadow/passwd_4.17.4-2_amd64.deb
SHA256: $1
@@policy
passwd:
  Installed: 1:4.17.4-2
  Candidate: 1:4.17.4-2
  Version table:
 *** 1:4.17.4-2 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
        100 /var/lib/dpkg/status
@@end
EOF
}

write_outside() { # <sha>
  cat >"${MOCKDIR}/resp_outside" <<EOF
@@kind
block
@@type
regular
@@size
15
@@sha256
$1
@@end
EOF
}

# Intentionally changed from v1: with no outside view the result is no longer
# "match" (exit 0); it is "match-unverified" (exit 4, trust self-reported).
@test "match-unverified: inside equals package but no outside view, exit 4" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 4 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "match-unverified" ]]
  [[ "$(jq -r .trust <<<"${output}")" == "self-reported" ]]
  [[ "$(jq -r .package <<<"${output}")" == "passwd" ]]
  [[ "$(jq -r .version <<<"${output}")" == "1:4.17.4-2" ]]
  [[ "$(jq -r .arch <<<"${output}")" == "amd64" ]]
  [[ "$(jq -r .sha256_inside <<<"${output}")" == "${PKG_SHA}" ]]
  [[ "$(jq -r .sha256_extracted <<<"${output}")" == "${PKG_SHA}" ]]
  [[ "$(jq -r .sha256_outside <<<"${output}")" == "null" ]]
  [[ "$(jq -r .deb_matches_apt_metadata <<<"${output}")" == "true" ]]
  [[ "$(jq -r .archive_signature <<<"${output}")" == "not-verified" ]]
  [[ "$(jq -r .deb_url <<<"${output}")" == "https://deb.debian.org/debian/pool/main/s/shadow/passwd_4.17.4-2_amd64.deb" ]]
}

@test "match with outside view: all three hashes equal, exit 0" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  assert_success
  [[ "$(jq -r .verdict <<<"${output}")" == "match" ]]
  [[ "$(jq -r .trust <<<"${output}")" == "outside-verified" ]]
  [[ "$(jq -r .sha256_outside <<<"${output}")" == "${PKG_SHA}" ]]
  [[ "$(jq -r .inputs.ctid <<<"${output}")" == "123" ]]
  grep -q outside "${MOCKDIR}/ssh.markers"
}

@test "markdown format emits a compact block with the verdict" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --format md
  assert_success
  assert_output --partial "verdict: **match**"
  assert_output --partial "trust: **outside-verified**"
  assert_output --partial "${PKG_SHA}"
  assert_output --partial "not-verified"
}

@test "mismatch (inside): live file differs from package file, exit 1" {
  write_ownership "$(sha_of tampered)"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "mismatch" ]]
}

@test "mismatch (outside): outside read differs, exit 1" {
  write_outside "$(sha_of tampered-outside)"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "mismatch" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *outside* ]]
}

@test "outside view requested but unreadable is an error, exit 3" {
  printf '@@error\nno rootfs in pct config\n' >"${MOCKDIR}/resp_outside"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
}

@test "package-unknown: path not owned by any package, exit 2" {
  cat >"${MOCKDIR}/resp_ownership" <<EOF
@@resolved
/usr/bin/chsh
@@owner

@@divert
truename=/usr/bin/chsh
listpackage=
@@sha256
${PKG_SHA}
@@end
EOF
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 2 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "package-unknown" ]]
  [[ ! -s "${MOCKDIR}/curl.log" ]]
}

@test "package-unknown: diverted path, exit 2" {
  sed -i 's/^listpackage=$/listpackage=other-pkg/' "${MOCKDIR}/resp_ownership"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 2 ]]
  [[ "$(jq -r .reason <<<"${output}")" == *diversion* ]]
}

@test "package-unknown: version missing from the target apt lists, exit 2" {
  printf '@@query\n1:4.17.4-2\namd64\n@@show\n@@policy\n@@end\n' >"${MOCKDIR}/resp_meta"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 2 ]]
}

@test "package-unknown: third-party apt origin without --mirror, exit 2" {
  sed -i 's#http://deb.debian.org/debian trixie/main#https://packages.example.org/repo stable/main#' "${MOCKDIR}/resp_meta"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 2 ]]
  [[ "$(jq -r .reason <<<"${output}")" == *unsupported* ]]
  [[ ! -s "${MOCKDIR}/curl.log" ]]
}

@test "package-unknown: 404 in the pool and not on snapshot, exit 2" {
  cat >"${MOCKBIN}/curl" <<'MOCK'
#!/usr/bin/env bash
printf '404'
MOCK
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 2 ]]
}

@test "snapshot.debian.org fallback is used when the pool no longer has the version" {
  echo 404 >"${MOCKDIR}/pool_code"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  assert_success
  grep -q 'snapshot.debian.org/file/' "${MOCKDIR}/curl.log"
  [[ "$(jq -r .deb_url <<<"${output}")" == https://snapshot.debian.org/file/* ]]
}

@test "deb hash differing from apt metadata is an error, never a match, exit 3" {
  write_meta "$(sha_of some-other-deb)"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .deb_matches_apt_metadata <<<"${output}")" == "false" ]]
  [[ ! -s "${MOCKDIR}/dpkg-deb.log" ]]
}

@test "ssh failure is an error, exit 3" {
  : >"${MOCKDIR}/ssh_fail_ownership"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
}

# Intentionally changed from v1 (which asserted "-x" only): the tool no longer
# extracts to disk, so the only allowed modes are -f and --fsys-tarfile.
@test "dpkg-deb is only ever called with -f or --fsys-tarfile (never extracts, installs or runs scripts)" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  assert_success
  [[ -s "${MOCKDIR}/dpkg-deb.log" ]]
  run grep -Ev '^(-f |--fsys-tarfile )' "${MOCKDIR}/dpkg-deb.log"
  assert_failure
}

@test "path validation rejects injection attempts before any ssh call" {
  local bad
  for bad in '/usr/bin/x; rm -rf /' '/usr/bin/$(id)' '/usr/bin/../../etc/passwd' '/usr/bin/a b' 'relative/path' '/usr/bin/a|b' '/usr/bin/a&b' '/usr/bin/x/' '/usr/bin/a>b' '/usr/bin/a*'; do
    run "${TOOL}" --host target1 --path "${bad}"
    [[ "${status}" -eq 3 ]] || { echo "accepted: ${bad}"; false; }
  done
  run "${TOOL}" --host target1 --path "$(printf '/usr/bin/a\nb')"
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --host target1 --path '/usr/bin/`id`'
  [[ "${status}" -eq 3 ]]
  [[ ! -e "${MOCKDIR}/ssh.log" ]]
}

@test "host, pve-host, ctid and mirror validation rejects bad values" {
  run "${TOOL}" --host '-oProxyCommand=x' --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --host 'h;id' --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --host t --path /usr/bin/chsh --pve-host p --ctid '123;id'
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --host t --path /usr/bin/chsh --pve-host p
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --host t --path /usr/bin/chsh --mirror 'file:///etc'
  [[ "${status}" -eq 3 ]]
  [[ ! -e "${MOCKDIR}/ssh.log" ]]
}

@test "usage: missing --path or --host, bad --format, unknown flag all exit 3" {
  run "${TOOL}" --host t
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --host t --path /usr/bin/chsh --format xml
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --nope
  [[ "${status}" -eq 3 ]]
}

@test "--help documents exit codes and exits 0" {
  run "${TOOL}" --help
  assert_success
  assert_output --partial "package-unknown"
  assert_output --partial "not-verified"
}

@test "temp dir is removed after match, mismatch, and error runs" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  assert_success
  [[ -z "$(ls -A "${RUNTMP}")" ]]
  write_ownership "$(sha_of tampered)"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 1 ]]
  [[ -z "$(ls -A "${RUNTMP}")" ]]
  write_meta "$(sha_of other)"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ -z "$(ls -A "${RUNTMP}")" ]]
}

@test "--inside-via-pct runs inside commands through pct exec on the pve host" {
  run "${TOOL}" --inside-via-pct --pve-host pve1 --ctid 123 --path /usr/bin/chsh
  assert_success
  grep -q 'pct exec 123 -- sh -s' "${MOCKDIR}/ssh.log"
}

@test "tool source contains no state-changing commands" {
  local bad
  for bad in 'pct mount' 'debugfs -w' 'apt-get install' 'dpkg -i' 'apt install' 'dpkg-deb -i' 'dpkg-deb -x' 'dpkg-deb -e'; do
    run grep -F -- "${bad}" "${TOOL}"
    [[ "${status}" -ne 0 ]] || { echo "found: ${bad}"; false; }
  done
}

# ---- trust model (Daybreak review of PR 25) ----

@test "match requires an outside view: no outside view never exits 0" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -ne 0 ]]
  [[ "$(jq -r .verdict <<<"${output}")" != "match" ]]
}

@test "outside hash is taken from the caller path, never the target-supplied resolved path" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  assert_success
  # the outside script is given the caller-supplied path as its second argument
  grep -Eq 'sh -s -- 123 /usr/bin/chsh$' "${MOCKDIR}/ssh.log"
}

@test "non-canonical path (target resolves it elsewhere) is an error, exit 3" {
  run "${TOOL}" --host target1 --path /bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == "pass the canonical path (target resolves it to /usr/bin/chsh)" ]]
  [[ ! -s "${MOCKDIR}/curl.log" ]]
}

@test "outside stat shows a symlink (not a regular file): error, exit 3" {
  sed -i 's/^regular$/symlink/' "${MOCKDIR}/resp_outside"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"not a regular file"* ]]
}

@test "directory-backed rootfs: outside view is null with a reason, match-unverified, exit 4" {
  printf '@@kind\ndir\n@@end\n' >"${MOCKDIR}/resp_outside"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 4 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "match-unverified" ]]
  [[ "$(jq -r .trust <<<"${output}")" == "self-reported" ]]
  [[ "$(jq -r .sha256_outside <<<"${output}")" == "null" ]]
  [[ "$(jq -r .sha256_outside_reason <<<"${output}")" == "unsupported rootfs type (directory-backed); outside view not taken" ]]
}

@test "outside script never reads a directory-backed rootfs and never writes" {
  run grep -nE 'sha256sum -- "\$dev|stat -c' "${TOOL}"
  assert_failure
}

@test "outside differs from package while inside matches: mismatch, exit 1, trust outside-verified" {
  write_outside "$(sha_of lie-from-hypervisor)"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .trust <<<"${output}")" == "outside-verified" ]]
}

@test ".deb control fields differing from the claimed package, version or arch: error, exit 3" {
  echo other-pkg >"${MOCKDIR}/ctrl_pkg"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"control fields"* ]]
  rm "${MOCKDIR}/ctrl_pkg"
  echo 9:9.9-9 >"${MOCKDIR}/ctrl_ver"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  rm "${MOCKDIR}/ctrl_ver"
  echo arm64 >"${MOCKDIR}/ctrl_arch"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
}

@test "package member is a symlink: error, exit 3" {
  echo symlink >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"link"* ]]
}

@test "package member is a hardlink: error, exit 3" {
  echo hardlink >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"link"* ]]
}

@test "package without the member is package-unknown; duplicate members are an error" {
  echo absent >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 2 ]]
  echo dup >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
}

@test "nothing is extracted to disk: no files appear under the work area during a run" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123
  assert_success
  # the mock builds its trees under MOCKDIR and removes them; the runner temp is clean
  [[ -z "$(ls -A "${RUNTMP}")" ]]
}

@test "download is restricted to https with a size cap and timeout" {
  run grep -F -- "--proto '=https' --proto-redir '=https'" "${TOOL}"
  assert_success
  run grep -F -- "--max-filesize 209715200" "${TOOL}"
  assert_success
  run grep -F -- "--max-time" "${TOOL}"
  assert_success
  run "${TOOL}" --host t --path /usr/bin/chsh --mirror 'http://mirror.example.org/debian'
  [[ "${status}" -eq 3 ]]
}

# ---- hostile target strings ----

hostile_divert() {
  # first line carries Markdown/HTML metacharacters and a CR; later lines
  # try to forge table rows (only the first line of a section is used).
  printf '@@resolved\n/usr/bin/chsh\n@@owner\npasswd: /usr/bin/chsh\n@@divert\ntruename=/usr/bin/chsh\n' >"${MOCKDIR}/resp_ownership"
  printf 'listpackage=evil|`pkg`**bold**[x](http://e.example)<img src=x>\r\033[31m\n| injected | row |\n@@sha256\n%s\n@@end\n' "${PKG_SHA}" >>"${MOCKDIR}/resp_ownership"
}

@test "markdown: hostile target text is escaped, control chars stripped, no forged rows" {
  hostile_divert
  run "${TOOL}" --host target1 --path /usr/bin/chsh --format md
  [[ "${status}" -eq 2 ]]
  # no raw metacharacters survive from the hostile value
  [[ "${output}" != *'evil|'* ]]
  ! grep -Eq '(^|[^\\])[<>]' <<<"${output}"
  [[ "${output}" != *'[x](http'* ]]
  [[ "${output}" != *'**bold**'* ]]
  [[ "${output}" == *'evil\|\`pkg\`\*\*bold\*\*\[x\]'* ]]
  # no control characters at all
  ! grep -q $'\r' <<<"${output}"
  ! grep -q $'\033' <<<"${output}"
  # the forged row did not become a line of its own
  ! grep -q '^| injected' <<<"${output}"
}

@test "markdown: long target values are truncated" {
  long="$(printf 'a%.0s' $(seq 1 600))"
  printf '@@error\n%s\n' "${long}" >"${MOCKDIR}/resp_ownership"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --format md
  [[ "${status}" -eq 3 ]]
  [[ "${#output}" -lt 1500 ]]
  [[ "${output}" != *"${long}"* ]]
}

@test "markdown: hostile apt origin suite is escaped" {
  sed -i 's#trixie/main amd64#tri|x`i/m*in amd64#' "${MOCKDIR}/resp_meta"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --format md
  assert_success
  [[ "${output}" != *'tri|x'* ]]
  [[ "${output}" == *'tri\|x\`i/m\*in'* ]]
}

@test "json: stays valid with hostile target strings, reason preserved verbatim" {
  hostile_divert
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 2 ]]
  jq -e . <<<"${output}" >/dev/null
  [[ "$(jq -r .reason <<<"${output}")" == *'evil|`pkg`**bold**'* ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "package-unknown" ]]
}
