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
  */dists/*/InRelease)
    code="$(cat "${MOCKDIR}/ir_code" 2>/dev/null || echo 404)"
    [[ "${code}" == 200 ]] && cp "${MOCKDIR}/InRelease" "${out}"
    printf '%s' "${code}" ;;
  */dists/*/Packages.xz | */dists/*/Packages.gz | */dists/*/by-hash/SHA256/*)
    code="$(cat "${MOCKDIR}/idx_code" 2>/dev/null || echo 404)"
    [[ "${code}" == 200 ]] && cp "${MOCKDIR}/index_payload" "${out}"
    printf '%s' "${code}" ;;
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
    [[ "$(cat "${MOCKDIR}/tar_mode" 2>/dev/null)" == hang ]] && exec sleep 30
    d="$(mktemp -d "${MOCKDIR}/tree.XXXXXX")"
    mkdir -p "${d}/usr/bin" "${d}/bin"
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
      many)
        cp "${MOCKDIR}/extract_content" "${d}/usr/bin/chsh"
        members=(./usr/bin/chsh ./usr/bin/chsh ./usr/bin/chsh ./usr/bin/chsh ./usr/bin/chsh) ;;
      aliased) cp "${MOCKDIR}/extract_content" "${d}/bin/chsh"; members=(./bin/chsh) ;;
      longlink)
        # a symlink whose PAX link target is ~100 KB (a crafted record)
        ln -s /bin/true "${d}/usr/bin/chsh"; members=(./usr/bin/chsh)
        tar --format=pax --pax-option="linkpath=$(head -c 100000 /dev/zero | tr '\0' a)" \
          -cf - -C "${d}" "${members[@]}"
        rm -rf "${d}"
        exit 0 ;;
    esac
    tar -cf - -C "${d}" "${members[@]}"
    rm -rf "${d}" ;;
  *) echo "unexpected dpkg-deb mode: $1" >&2; exit 2 ;;
esac
MOCK
  chmod +x "${MOCKBIN}/ssh" "${MOCKBIN}/curl" "${MOCKBIN}/dpkg-deb"
}

# The alias section and alias_* diversion lines are only read when dpkg
# registered a path other than the canonical one (the real target script only
# emits them in that case). ALIAS_RESOLVES, ALIAS_DIVERT_PKG and
# ALIAS_DIVERT_TRUE let a test change what the target reports about the alias.
write_ownership() { # <live sha> [owner path] [live size]
  cat >"${MOCKDIR}/resp_ownership" <<EOF
@@resolved
/usr/bin/chsh
@@owner
passwd: ${2:-/usr/bin/chsh}
@@divert
truename=/usr/bin/chsh
listpackage=
alias_truename=${ALIAS_DIVERT_TRUE-${2:-/usr/bin/chsh}}
alias_listpackage=${ALIAS_DIVERT_PKG-}
@@alias
${2:-/usr/bin/chsh}
${ALIAS_RESOLVES-/usr/bin/chsh}
@@size
${3:-15}
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

write_outside() { # <sha> [stat size] [bytes read]
  cat >"${MOCKDIR}/resp_outside" <<EOF
@@kind
block
@@type
regular
@@size
${2:-15}
@@sha256
$1
@@bytes
${3:-${2:-15}}
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  assert_success
  [[ "$(jq -r .verdict <<<"${output}")" == "match" ]]
  [[ "$(jq -r .trust <<<"${output}")" == "outside-verified" ]]
  [[ "$(jq -r .sha256_outside <<<"${output}")" == "${PKG_SHA}" ]]
  [[ "$(jq -r .inputs.ctid <<<"${output}")" == "123" ]]
  grep -q outside "${MOCKDIR}/ssh.markers"
}

@test "markdown format emits a compact block with the verdict" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check --format md
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "mismatch" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *outside* ]]
}

@test "outside view requested but unreadable is an error, exit 3" {
  printf '@@error\nno rootfs in pct config\n' >"${MOCKDIR}/resp_outside"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
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
@@size
15
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
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
  run "${TOOL}" --inside-via-pct --pve-host pve1 --ctid 123 --no-archive-check --path /usr/bin/chsh
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"not a regular file"* ]]
}

@test "directory-backed rootfs: outside view is null with a reason, match-unverified, exit 4" {
  printf '@@kind\ndir\n@@end\n' >"${MOCKDIR}/resp_outside"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .trust <<<"${output}")" == "outside-verified" ]]
}

@test ".deb control fields differing from the claimed package, version or arch: error, exit 3" {
  echo other-pkg >"${MOCKDIR}/ctrl_pkg"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"control fields"* ]]
  rm "${MOCKDIR}/ctrl_pkg"
  echo 9:9.9-9 >"${MOCKDIR}/ctrl_ver"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  rm "${MOCKDIR}/ctrl_ver"
  echo arm64 >"${MOCKDIR}/ctrl_arch"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
}

@test "package member is a symlink: error, exit 3" {
  echo symlink >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"link"* ]]
}

@test "package member is a hardlink: error, exit 3" {
  echo hardlink >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"link"* ]]
}

@test "package without the member is package-unknown; duplicate members are an error" {
  echo absent >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 2 ]]
  echo dup >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
}

@test "nothing is extracted to disk: no files appear under the work area during a run" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  assert_success
  # the mock builds its trees under MOCKDIR and removes them; the runner temp is clean
  [[ -z "$(ls -A "${RUNTMP}")" ]]
}

@test "download is restricted to https with a size cap and timeout" {
  run grep -F -- "--proto '=https' --proto-redir '=https'" "${TOOL}"
  assert_success
  run grep -F -- '--max-filesize "${3:-209715200}"' "${TOOL}"
  assert_success
  # archive check caps: InRelease 1 MiB, index 128 MiB
  run grep -F -- '1048576' "${TOOL}"
  assert_success
  run grep -F -- '134217728' "${TOOL}"
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
  printf 'listpackage=evil|`pkg`**bold**[x](http://e.example)<img src=x>\r\033[31m\n| injected | row |\n@@size\n15\n@@sha256\n%s\n@@end\n' "${PKG_SHA}" >>"${MOCKDIR}/resp_ownership"
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check --format md
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

# ---- second review round (Opus + Daybreak re-review of e7c30ac) ----

reason_of() { jq -r .reason <<<"${output}"; }

@test "outside returns the empty-input hash for a non-empty file (failed debugfs read): error, exit 3" {
  write_outside e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 15 0
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(reason_of)" == *"incomplete"* ]]
  [[ "$(jq -r .sha256_outside <<<"${output}")" == "null" ]]
}

@test "outside byte count differs from the stat size: error, exit 3" {
  write_outside "${PKG_SHA}" 15 7
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"read 7 bytes"* ]]
}

@test "outside script runs under bash with pipefail and reports a failed read as @@error" {
  run grep -F 'set -o pipefail' "${TOOL}"
  assert_success
  run grep -F 'bash -s --' "${TOOL}"
  assert_success
  run grep -F '@@bytes' "${TOOL}"
  assert_success
}

@test "empty-input hash on the live file with a non-empty size is an error, exit 3" {
  write_ownership e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 /usr/bin/chsh 15
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ ! -s "${MOCKDIR}/curl.log" ]]
}

@test "inside size differing from the package size while hashes agree is an error, exit 3" {
  write_ownership "${PKG_SHA}" /usr/bin/chsh 99
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"size"* ]]
}

@test "inside mismatch is reported even when the outside ssh fails: exit 1, reason recorded" {
  write_ownership "$(sha_of tampered)"
  : >"${MOCKDIR}/ssh_fail_outside"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "mismatch" ]]
  [[ "$(reason_of)" == *"outside view also failed"* ]]
  [[ "$(jq -r .sha256_outside_reason <<<"${output}")" == *"unavailable"* ]]
}

@test "inside mismatch is reported even when the outside file is not regular: exit 1" {
  write_ownership "$(sha_of tampered)"
  sed -i 's/^regular$/symlink/' "${MOCKDIR}/resp_outside"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "mismatch" ]]
}

@test "usrmerge alias: dpkg registers /bin/chsh, canonical /usr/bin/chsh is verified" {
  write_ownership "${PKG_SHA}" /bin/chsh
  echo aliased >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  assert_success
  [[ "$(jq -r .verdict <<<"${output}")" == "match" ]]
  [[ "$(jq -r .dpkg_path <<<"${output}")" == "/bin/chsh" ]]
  [[ "$(jq -r .resolved_path <<<"${output}")" == "/usr/bin/chsh" ]]
  # the outside view still reads the canonical path
  grep -Eq 'sh -s -- 123 /usr/bin/chsh$' "${MOCKDIR}/ssh.log"
}

@test "usrmerge alias: dpkg path that is neither the path nor its alias is an error, exit 3" {
  write_ownership "${PKG_SHA}" /usr/bin/other
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"unrelated path"* ]]
  [[ ! -s "${MOCKDIR}/curl.log" ]]
}

@test "download network failure (000) and server errors (5xx) are errors; 404 stays package-unknown" {
  echo 503 >"${MOCKDIR}/pool_code"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  echo 000 >"${MOCKDIR}/pool_code"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  echo 404 >"${MOCKDIR}/pool_code"
  rm "${MOCKBIN}/curl"
  cat >"${MOCKBIN}/curl" <<'MOCK'
#!/usr/bin/env bash
printf '404'
MOCK
  chmod +x "${MOCKBIN}/curl"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 2 ]]
}

@test "snapshot lookup server error is an error, not package-unknown" {
  echo 404 >"${MOCKDIR}/pool_code"
  cat >"${MOCKBIN}/curl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in *snapshot.debian.org*) printf '503' ;; *) printf '404' ;; esac
MOCK
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"snapshot.debian.org lookup failed"* ]]
}

@test "missing dependency exits 3 with a message before any jq output" {
  local nojq="${BATS_TEST_TMPDIR}/nojq" c
  mkdir -p "${nojq}"
  for c in bash curl dpkg-deb tar ssh sha256sum timeout; do
    ln -s "$(command -v "${c}")" "${nojq}/${c}"
  done
  run env PATH="${nojq}" "$(command -v bash)" "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "${output}" == *"missing required command(s): jq"* ]]
  [[ ! -e "${MOCKDIR}/ssh.log" ]]
}

@test "more than two matching members: stops after two and is an error, exit 3" {
  echo many >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"more than one entry"* ]]
}

@test "decoder timeout yields error, exit 3 (decompression-bomb guard)" {
  echo hang >"${MOCKDIR}/tar_mode"
  PV_DECODER_TIMEOUT=1 run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(reason_of)" == *"could not list"* ]]
}

@test "oversized control-field output is an error, exit 3" {
  printf 'x%.0s' $(seq 1 5000) >"${MOCKDIR}/ctrl_pkg"
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"oversized"* ]]
}

@test "every decoder call goes through the bounded decoder wrapper" {
  # direct dpkg-deb/tar invocations (outside comments and help text) must be prefixed by decoder
  run bash -c "grep -nE 'dpkg-deb (-f|--fsys-tarfile)|tar -[a-zA-Z]+f' '${TOOL}' | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'decoder \|finish '"
  [[ "${status}" -ne 0 ]]
  run grep -c 'decoder dpkg-deb' "${TOOL}"
  [[ "${output}" -ge 3 ]]
}

@test "hardlink reason names the link target" {
  echo hardlink >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"verify that path instead"* ]]
  [[ "$(reason_of)" == *"/usr/bin/aaa"* ]]
}

# ---- review round 3 ----

@test "every --fsys-tarfile invocation carries --threads-max=1 (xz decoder fits the memory cap)" {
  # source: no decoder dpkg-deb --fsys-tarfile call lacks --threads-max=1
  run bash -c "grep -n -e 'decoder dpkg-deb --fsys-tarfile' '${TOOL}' | grep -v -e '--threads-max=1'"
  [[ "${status}" -ne 0 ]]
  run grep -c -e 'decoder dpkg-deb --fsys-tarfile --threads-max=1' "${TOOL}"
  [[ "${output}" -ge 2 ]]
  # runtime: every recorded --fsys-tarfile call had it
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  assert_success
  grep -q -e '--fsys-tarfile' "${MOCKDIR}/dpkg-deb.log"
  run bash -c "grep -e '--fsys-tarfile' '${MOCKDIR}/dpkg-deb.log' | grep -v -e '--threads-max=1'"
  [[ "${status}" -ne 0 ]]
}

# Run the real OUTSIDE_SCRIPT text against mock pct, pvesm and debugfs. Only
# the block-device test is relaxed (a regular file stands in for the device).
run_outside_script() { # <debugfs cat mode>
  local script="${BATS_TEST_TMPDIR}/outside.sh" bin="${BATS_TEST_TMPDIR}/obin"
  mkdir -p "${bin}"
  : >"${BATS_TEST_TMPDIR}/fakedev"
  sed -n "/^OUTSIDE_SCRIPT='/,/^'\$/p" "${TOOL}" | sed -e "1s/^OUTSIDE_SCRIPT='//" -e '$d' \
    | sed 's/\[ -b "\$dev" \]/[ -e "$dev" ]/' >"${script}"
  cat >"${bin}/pct" <<'M'
#!/usr/bin/env bash
echo "rootfs: local:123/vm-123-disk-0.raw,size=8G"
M
  cat >"${bin}/pvesm" <<M
#!/usr/bin/env bash
echo "${BATS_TEST_TMPDIR}/fakedev"
M
  cat >"${bin}/debugfs" <<'M'
#!/usr/bin/env bash
echo "$2" >>"${MOCKDIR}/debugfs.log"
case "$2" in
  stat*) echo "Inode: 12   Type: regular    Mode:  0755   Flags: 0x80000"; echo "User:     0   Group:     0   Size: 15" ;;
  cat*)
    case "$(cat "${MOCKDIR}/debugfs_mode" 2>/dev/null)" in
      partial) printf 'pristine'; exit 1 ;;
      *) printf 'pristine-binary' ;;
    esac ;;
esac
M
  chmod +x "${bin}/pct" "${bin}/pvesm" "${bin}/debugfs"
  echo "$1" >"${MOCKDIR}/debugfs_mode"
  PATH="${bin}:${PATH}" run bash -s -- 123 /usr/bin/chsh <"${script}"
}

@test "outside view hashes and counts in a single debugfs read" {
  run_outside_script full
  assert_success
  [[ "$(grep -c '^cat ' "${MOCKDIR}/debugfs.log")" -eq 1 ]]
  [[ "$(sed -n '/^@@sha256$/{n;p}' <<<"${output}")" == "${PKG_SHA}" ]]
  [[ "$(sed -n '/^@@bytes$/{n;p}' <<<"${output}")" == "15" ]]
}

@test "outside view: a partial single read is an @@error, never a hash paired with a count" {
  run_outside_script partial
  assert_success
  [[ "${output}" == *"@@error"* ]]
  [[ "${output}" != *"@@sha256"* ]]
  [[ "$(grep -c '^cat ' "${MOCKDIR}/debugfs.log")" -eq 1 ]]
}

@test "usrmerge alias: a diversion on the alias path is package-unknown, exit 2" {
  ALIAS_DIVERT_PKG=localpkg write_ownership "${PKG_SHA}" /bin/chsh
  echo aliased >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 2 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "package-unknown" ]]
  [[ "$(reason_of)" == *"alias path /bin/chsh"*"diversion"* ]]
  [[ ! -s "${MOCKDIR}/curl.log" ]]
}

@test "usrmerge alias: a diverted truename on the alias path is package-unknown, exit 2" {
  ALIAS_DIVERT_TRUE=/bin/chsh.distrib write_ownership "${PKG_SHA}" /bin/chsh
  echo aliased >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 2 ]]
  [[ "$(reason_of)" == *"diversion"* ]]
}

@test "usrmerge alias: alias that does not resolve to the canonical path is ignored, exit 2" {
  ALIAS_RESOLVES=/opt/elsewhere/chsh write_ownership "${PKG_SHA}" /bin/chsh
  echo aliased >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 2 ]]
  [[ "$(reason_of)" == *"alias is ignored"* ]]
  [[ ! -s "${MOCKDIR}/curl.log" ]]
}

@test "ownership script only accepts an alias after readlink -f resolves it to the canonical path" {
  run grep -F 'readlink -f -- "$alt"' "${TOOL}"
  assert_success
  run grep -F '[ "$alias_real" = "$r" ]' "${TOOL}"
  assert_success
}

@test "crafted PAX link target (~100 KB) stays bounded: member is rejected as a link, exit 3" {
  echo longlink >"${MOCKDIR}/tar_mode"
  run "${TOOL}" --host target1 --path /usr/bin/chsh --pve-host pve1 --ctid 123 --no-archive-check
  [[ "${status}" -eq 3 ]]
  [[ "$(reason_of)" == *"link or special entry"* ]]
  [[ "${#output}" -lt 4000 ]]
}

@test "listing parser stage (cut and awk) runs under the bounded decoder wrapper and emits bounded fields" {
  run grep -F 'decoder cut -b' "${TOOL}"
  assert_success
  run grep -F 'decoder awk' "${TOOL}"
  assert_success
  run grep -F 'substr(name, 1, 512)' "${TOOL}"
  assert_success
  run grep -F 'substr(tgt, 1, 256)' "${TOOL}"
  assert_success
}

@test "limit overrides: out-of-range or malformed values are rejected with exit 3" {
  for v in 0 -1 3601 abc 1.5 99999999; do
    PV_DECODER_TIMEOUT="$v" run "${TOOL}" --host target1 --path /usr/bin/chsh
    [[ "${status}" -eq 3 ]]
    [[ "${output}" == *"PV_DECODER_TIMEOUT"* ]]
  done
  for v in 0 1024 262143 8388609 unlimited -5; do
    PV_DECODER_VMEM_KB="$v" run "${TOOL}" --host target1 --path /usr/bin/chsh
    [[ "${status}" -eq 3 ]]
    [[ "${output}" == *"PV_DECODER_VMEM_KB"* ]]
  done
  [[ ! -s "${MOCKDIR}/ssh.log" ]]
}

@test "limit overrides: boundary values are accepted" {
  PV_DECODER_TIMEOUT=1 PV_DECODER_VMEM_KB=262144 run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 4 ]]
  PV_DECODER_TIMEOUT=3600 PV_DECODER_VMEM_KB=8388608 run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "${status}" -eq 4 ]]
}

@test "memory cap that cannot be applied fails closed with exit 3 instead of running uncapped" {
  # Lower the hard limit below the requested cap so ulimit -v cannot be applied.
  run bash -c "ulimit -S -H -v 300000; PV_DECODER_VMEM_KB=1048576 '${TOOL}' --host target1 --path /usr/bin/chsh"
  [[ "${status}" -eq 3 ]]
  [[ "${output}" == *"cannot apply the decoder memory cap"* ]]
  [[ ! -s "${MOCKDIR}/ssh.log" ]]
  run grep -F 'ulimit -v "$PV_DECODER_VMEM_KB" 2>/dev/null || true' "${TOOL}"
  [[ "${status}" -ne 0 ]]
}

# ---------------------------------------------------------------------------
# Archive signature check (v1.4.0). A throwaway signing key is generated at test
# time; its public half is exported as the "archive keyring". Nothing here uses
# the system keyring or the network.
# ---------------------------------------------------------------------------

setup_file() {
  export GPGDIR_A="${BATS_FILE_TMPDIR}/gpgA" GPGDIR_B="${BATS_FILE_TMPDIR}/gpgB"
  local d
  for d in "${GPGDIR_A}" "${GPGDIR_B}"; do
    mkdir -m 700 "${d}"
    gpg --homedir "${d}" --batch --pinentry-mode loopback --passphrase '' \
      --quick-gen-key "pv-test-$(basename "${d}") <pv@example.invalid>" ed25519 sign never >/dev/null 2>&1
  done
  gpg --homedir "${GPGDIR_A}" --export >"${BATS_FILE_TMPDIR}/keyA.gpg"
  gpg --homedir "${GPGDIR_B}" --export >"${BATS_FILE_TMPDIR}/keyB.gpg"
  FPR_A="$(gpg --homedir "${GPGDIR_A}" --with-colons --list-keys | awk -F: '/^fpr/ {print $10; exit}')"
  export FPR_A
}

teardown_file() {
  gpgconf --homedir "${GPGDIR_A}" --kill all >/dev/null 2>&1 || true
  gpgconf --homedir "${GPGDIR_B}" --kill all >/dev/null 2>&1 || true
}

days_ago() { date -u -d "$1 days ago" '+%a, %d %b %Y %H:%M:%S UTC'; }
days_ahead() { date -u -d "$1 days" '+%a, %d %b %Y %H:%M:%S UTC'; }

# build_archive: write the index payload and a clearsigned MOCKDIR/InRelease.
# Knobs (env): AR_PKG (passwd), AR_STANZA_SHA (the .deb sha), AR_FILENAME,
# AR_STANZA_ARCH (amd64), AR_DUP (1 adds a second identical stanza),
# AR_DATE (now; "none" omits), AR_UNTIL (far future; "none" omits),
# AR_SIGNERS ("A", "B" or "A B"), AR_BYHASH (yes|no), AR_ONLYGZ (1 lists and
# serves only Packages.gz).
build_archive() {
  local pkg="${AR_PKG:-passwd}" sha="${AR_STANZA_SHA:-${DEB_SHA}}"
  local fn="${AR_FILENAME:-pool/main/s/shadow/passwd_4.17.4-2_amd64.deb}"
  local until="${AR_UNTIL:-Mon, 01 Jan 2057 00:00:00 UTC}" signers="${AR_SIGNERS:-A}"
  local adate="${AR_DATE:-$(date -u '+%a, %d %b %Y %H:%M:%S UTC')}" sarch="${AR_STANZA_ARCH:-amd64}"
  local stanza
  stanza="$(printf 'Package: %s\nVersion: 1:4.17.4-2\nArchitecture: %s\nFilename: %s\nSHA256: %s\nDescription: y\n\n' "${pkg}" "${sarch}" "${fn}" "${sha}")"
  {
    printf 'Package: other\nVersion: 1.0\nArchitecture: amd64\nFilename: pool/main/o/other/other_1.0_amd64.deb\nSHA256: %s\nDescription: x\n multi line\n\n' "$(sha_of other)"
    printf '%s\n\n' "${stanza}"
    [[ "${AR_DUP:-0}" == 1 ]] && printf '%s\n\n' "${stanza}"
  } >"${MOCKDIR}/packages.txt"
  xz -c <"${MOCKDIR}/packages.txt" >"${MOCKDIR}/Packages.xz"
  gzip -c <"${MOCKDIR}/packages.txt" >"${MOCKDIR}/Packages.gz"
  local xzline="" gzline ihash isize payload=Packages.xz
  [[ "${AR_ONLYGZ:-0}" == 1 ]] && payload=Packages.gz
  cp "${MOCKDIR}/${payload}" "${MOCKDIR}/index_payload"
  gzline=" $(sha256sum "${MOCKDIR}/Packages.gz" | cut -d' ' -f1) $(wc -c <"${MOCKDIR}/Packages.gz" | tr -d ' ') main/binary-amd64/Packages.gz"
  [[ "${AR_ONLYGZ:-0}" == 1 ]] || xzline=" $(sha256sum "${MOCKDIR}/Packages.xz" | cut -d' ' -f1) $(wc -c <"${MOCKDIR}/Packages.xz" | tr -d ' ') main/binary-amd64/Packages.xz"
  {
    printf 'Origin: Debian\nSuite: stable\nCodename: trixie\n'
    [[ "${adate}" == none ]] || printf 'Date: %s\n' "${adate}"
    [[ "${until}" == none ]] || printf 'Valid-Until: %s\n' "${until}"
    printf 'Acquire-By-Hash: %s\nSHA256:\n' "${AR_BYHASH:-yes}"
    [[ -z "${xzline}" ]] || printf '%s\n' "${xzline}"
    printf '%s\n' "${gzline}"
  } >"${MOCKDIR}/release.txt"
  local args=() k
  for k in ${signers}; do
    local dir="GPGDIR_${k}"
    args+=(--homedir "${!dir}" --local-user "$(gpg --homedir "${!dir}" --with-colons --list-keys | awk -F: '/^fpr/ {print $10; exit}')")
  done
  if [[ "${signers}" == "A B" ]]; then
    # Two signers need both secret keys in one homedir: import B's into A's.
    gpg --homedir "${GPGDIR_A}" --batch --pinentry-mode loopback --passphrase '' --yes \
      --import "${BATS_FILE_TMPDIR}/secB.asc" >/dev/null 2>&1
    gpg --homedir "${GPGDIR_A}" --batch --pinentry-mode loopback --passphrase '' --yes --clearsign \
      --local-user "${FPR_A}" --local-user "${FPR_B}" -o "${MOCKDIR}/InRelease" "${MOCKDIR}/release.txt" >/dev/null 2>&1
  else
    gpg "${args[@]}" --batch --pinentry-mode loopback --passphrase '' --yes --clearsign \
      -o "${MOCKDIR}/InRelease" "${MOCKDIR}/release.txt" >/dev/null 2>&1
  fi
  echo 200 >"${MOCKDIR}/ir_code"
  echo 200 >"${MOCKDIR}/idx_code"
}

# mock_gpgv <exit status | hang> <status line>...: replace gpgv with a canned
# verifier that writes the signed text (release.txt) to --output.
mock_gpgv() {
  local rc="$1"; shift
  printf '%s\n' "$@" >"${MOCKDIR}/gpgv_status"
  echo "${rc}" >"${MOCKDIR}/gpgv_rc"
  cat >"${MOCKBIN}/gpgv" <<'MOCK'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in --output) out="$2"; shift 2 ;; --homedir | --keyring | --status-fd) shift 2 ;; *) shift ;; esac
done
rc="$(cat "${MOCKDIR}/gpgv_rc")"
[[ "${rc}" == hang ]] && exec sleep 30
cat "${MOCKDIR}/gpgv_status" >&3
cp "${MOCKDIR}/release.txt" "${out}"
exit "${rc}"
MOCK
  chmod +x "${MOCKBIN}/gpgv"
}
VALID_LINE='[GNUPG:] VALIDSIG 4CB50190207B4758A3F73A796ED0E7B82643E131 2026-09-12 1789199779 0 4 0 22 8 01 4CB50190207B4758A3F73A796ED0E7B82643E131'

arch_run() { # extra args pass through
  run "${TOOL}" --host target1 --path /usr/bin/chsh --keyring "${BATS_FILE_TMPDIR}/keyA.gpg" "$@"
}
arch_state() { jq -r .archive_signature <<<"${output}"; }
arch_reason() { jq -r .archive_signature_detail.reason <<<"${output}"; }

@test "archive: good signature, index and stanza agree -> verified, fingerprint recorded" {
  build_archive
  arch_run
  [[ "${status}" -eq 4 ]]
  [[ "$(arch_state)" == "verified" ]]
  [[ "$(jq -r .archive_signature_detail.suite <<<"${output}")" == "trixie" ]]
  [[ "$(jq -r .archive_signature_detail.component <<<"${output}")" == "main" ]]
  [[ "$(jq -r .archive_signature_detail.index <<<"${output}")" == "main/binary-amd64/Packages.xz" ]]
  [[ "$(jq -r '.archive_signature_detail.signer_fingerprints[0]' <<<"${output}")" == "${FPR_A^^}" ]]
  grep -q '/dists/trixie/InRelease$' "${MOCKDIR}/curl.log"
  grep -q '/by-hash/SHA256/' "${MOCKDIR}/curl.log"
}

@test "archive: without Acquire-By-Hash the plain index path is used" {
  AR_BYHASH=no build_archive
  arch_run
  [[ "$(arch_state)" == "verified" ]]
  grep -q '/main/binary-amd64/Packages.xz$' "${MOCKDIR}/curl.log"
  ! grep -q '/by-hash/' "${MOCKDIR}/curl.log"
}

@test "archive: Packages.gz fallback when the release lists only gz" {
  AR_ONLYGZ=1 build_archive
  arch_run
  [[ "$(arch_state)" == "verified" ]]
  [[ "$(jq -r .archive_signature_detail.index <<<"${output}")" == "main/binary-amd64/Packages.gz" ]]
}

@test "archive: -security suite uses its own InRelease URL" {
  sed -i 's#500 http://deb.debian.org/debian trixie/main#500 http://security.debian.org/debian-security trixie-security/main#' "${MOCKDIR}/resp_meta"
  build_archive
  arch_run
  [[ "$(arch_state)" == "verified" ]]
  [[ "$(jq -r .archive_signature_detail.suite <<<"${output}")" == "trixie-security" ]]
  grep -qx 'https://security.debian.org/debian-security/dists/trixie-security/InRelease' "${MOCKDIR}/curl.log"
}

@test "archive: an arch all stanza is found in the binary-amd64 index" {
  sed -i -e '3s/amd64/all/' -e 's/^Architecture: amd64/Architecture: all/' "${MOCKDIR}/resp_meta"
  echo all >"${MOCKDIR}/ctrl_arch"
  AR_STANZA_ARCH=all AR_FILENAME=pool/main/s/shadow/passwd_4.17.4-2_amd64.deb build_archive
  arch_run
  [[ "$(arch_state)" == "verified" ]]
  [[ "$(jq -r .arch <<<"${output}")" == "all" ]]
}

@test "archive: duplicate stanza in the signed index -> not-verified" {
  AR_DUP=1 build_archive
  arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"more than once"* ]]
}

@test "archive: default keyring for a Debian origin comes from the Debian keyring path" {
  build_archive
  PV_DEBIAN_KEYRING="${BATS_FILE_TMPDIR}/keyA.gpg" PV_UBUNTU_KEYRING=/nonexistent/ubuntu.gpg \
    run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "$(arch_state)" == "verified" ]]
  PV_DEBIAN_KEYRING=/nonexistent/debian.gpg PV_UBUNTU_KEYRING="${BATS_FILE_TMPDIR}/keyA.gpg" \
    run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"/nonexistent/debian.gpg"* ]]
}

@test "archive: default keyring for an Ubuntu origin comes from the Ubuntu keyring path" {
  sed -i 's#500 http://deb.debian.org/debian trixie/main#500 http://archive.ubuntu.com/ubuntu noble-updates/main#' "${MOCKDIR}/resp_meta"
  build_archive
  PV_DEBIAN_KEYRING=/nonexistent/debian.gpg PV_UBUNTU_KEYRING="${BATS_FILE_TMPDIR}/keyA.gpg" \
    run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "$(arch_state)" == "verified" ]]
  grep -qx 'https://archive.ubuntu.com/ubuntu/dists/noble-updates/InRelease' "${MOCKDIR}/curl.log"
  PV_DEBIAN_KEYRING="${BATS_FILE_TMPDIR}/keyA.gpg" PV_UBUNTU_KEYRING=/nonexistent/ubuntu.gpg \
    run "${TOOL}" --host target1 --path /usr/bin/chsh
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"/nonexistent/ubuntu.gpg"* ]]
}

@test "archive: signature by a key not in the keyring -> not-verified, keyring may be stale" {
  AR_SIGNERS=B build_archive
  arch_run
  [[ "${status}" -eq 4 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "match-unverified" ]]
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"no signature from a key in"* ]]
  [[ "$(arch_reason)" == *"keyring may be stale"* ]]
}

@test "archive: no gpgv status lines at all -> not-verified" {
  build_archive
  mock_gpgv 2
  arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"keyring may be stale"* ]]
}

@test "archive: tampered InRelease body -> failed, exit 3" {
  build_archive
  sed -i 's/^Suite: stable/Suite: tampered/' "${MOCKDIR}/InRelease"
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(arch_state)" == "failed" ]]
  [[ "$(arch_reason)" == *"BADSIG"* ]]
}

@test "archive: EXPKEYSIG and REVKEYSIG next to a valid signature -> failed" {
  build_archive
  local st
  for st in EXPKEYSIG REVKEYSIG; do
    mock_gpgv 1 "${VALID_LINE}" "[GNUPG:] ${st} 6ED0E7B82643E131 Test Key"
    arch_run
    [[ "${status}" -eq 3 ]]
    [[ "$(arch_state)" == "failed" ]]
    [[ "$(arch_reason)" == *"${st}"* ]]
  done
}

@test "archive: ERRSIG with a reason other than a missing key -> not-verified" {
  build_archive
  mock_gpgv 2 "${VALID_LINE}" '[GNUPG:] ERRSIG 78DBA3BC47EF2265 1 8 01 1789199779 4 B8E5F13B'
  arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"other than a missing key"* ]]
}

@test "archive: ERRSIG reason 9 (missing key) beside a valid signature is tolerated" {
  build_archive
  mock_gpgv 2 "${VALID_LINE}" '[GNUPG:] ERRSIG 78DBA3BC47EF2265 1 8 01 1789199779 9 B8E5F13B' '[GNUPG:] NO_PUBKEY 78DBA3BC47EF2265'
  arch_run
  [[ "$(arch_state)" == "verified" ]]
}

@test "archive: NODATA or FAILURE status -> not-verified" {
  build_archive
  local st
  for st in NODATA FAILURE; do
    mock_gpgv 2 "${VALID_LINE}" "[GNUPG:] ${st} 1"
    arch_run
    [[ "$(arch_state)" == "not-verified" ]]
    [[ "$(arch_reason)" == *"NODATA or FAILURE"* ]]
  done
}

@test "archive: gpgv non-zero exit or timeout after a valid line -> not-verified" {
  build_archive
  mock_gpgv 1 "${VALID_LINE}"
  arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"gpgv exited with status 1"* ]]
  mock_gpgv hang "${VALID_LINE}"
  PV_DECODER_TIMEOUT=1 arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"gpgv exited with status"* ]]
}

@test "archive: one good signature plus one unknown-key signature -> verified" {
  gpg --homedir "${GPGDIR_B}" --batch --pinentry-mode loopback --passphrase '' --export-secret-keys --armor >"${BATS_FILE_TMPDIR}/secB.asc"
  FPR_B="$(gpg --homedir "${GPGDIR_B}" --with-colons --list-keys | awk -F: '/^fpr/ {print $10; exit}')"
  export FPR_B
  AR_SIGNERS="A B" build_archive
  arch_run
  [[ "$(arch_state)" == "verified" ]]
  [[ "$(jq -r '.archive_signature_detail.signer_fingerprints | length' <<<"${output}")" -eq 1 ]]
}

@test "archive: by-hash index that differs from the signed hash -> failed" {
  AR_BYHASH=yes build_archive
  { printf 'Package: extra\n\n'; cat "${MOCKDIR}/packages.txt"; } | xz -c >"${MOCKDIR}/index_payload"
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(arch_state)" == "failed" ]]
  [[ "$(arch_reason)" == *"does not match the size and SHA256"* ]]
}

@test "archive: plain-path index that differs from the signed hash -> not-verified (mid-sync)" {
  AR_BYHASH=no build_archive
  { printf 'Package: extra\n\n'; cat "${MOCKDIR}/packages.txt"; } | xz -c >"${MOCKDIR}/index_payload"
  arch_run
  [[ "${status}" -eq 4 ]]
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"index changed during fetch (mirror mid-sync) or was altered"* ]]
}

@test "archive: signed stanza SHA256 disagrees with the target apt SHA256 -> failed, exit 3" {
  AR_STANZA_SHA="$(sha_of forged)" build_archive
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(arch_state)" == "failed" ]]
  [[ "$(arch_reason)" == *"possible tampering"* ]]
}

@test "archive: signed Filename disagrees with the target Filename -> failed" {
  AR_FILENAME=pool/main/x/evil/passwd_4.17.4-2_amd64.deb build_archive
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(arch_state)" == "failed" ]]
}

@test "archive: package absent from the signed index -> not-verified, verdict unchanged" {
  AR_PKG=notpasswd build_archive
  arch_run
  [[ "${status}" -eq 4 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "match-unverified" ]]
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"not in the current signed index"* ]]
}

@test "archive: InRelease 404 and 000 -> not-verified, verdict unchanged" {
  build_archive
  local c
  for c in 404 000; do
    echo "${c}" >"${MOCKDIR}/ir_code"
    arch_run
    [[ "${status}" -eq 4 ]]
    [[ "$(arch_state)" == "not-verified" ]]
    [[ "$(arch_reason)" == *"InRelease"* ]]
  done
}

@test "archive: index fetch failure -> not-verified" {
  build_archive
  echo 404 >"${MOCKDIR}/idx_code"
  arch_run
  [[ "${status}" -eq 4 ]]
  [[ "$(arch_state)" == "not-verified" ]]
}

@test "archive: --no-archive-check -> not-verified with a clear reason and no extra downloads" {
  build_archive
  arch_run --no-archive-check
  [[ "${status}" -eq 4 ]]
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == "disabled by --no-archive-check" ]]
  [[ "$(wc -l <"${MOCKDIR}/curl.log")" -eq 1 ]]
}

@test "archive: gpgv missing from PATH -> not-verified, never an error" {
  build_archive
  local clean="${BATS_TEST_TMPDIR}/nogpgv" d
  mkdir -p "${clean}"
  for d in /usr/local/bin /usr/bin; do
    find "${d}" -maxdepth 1 \( -type f -o -type l \) ! -name gpgv -exec ln -sf -t "${clean}" {} + 2>/dev/null
  done
  PATH="${MOCKBIN}:${clean}" arch_run
  [[ "${status}" -eq 4 ]]
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"gpgv is not installed"* ]]
}

@test "archive: expired Valid-Until -> failed" {
  AR_UNTIL="Mon, 01 Jan 2024 00:00:00 UTC" build_archive
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(arch_state)" == "failed" ]]
  [[ "$(arch_reason)" == *"expired"* ]]
}

@test "archive: unparseable Valid-Until -> failed" {
  AR_UNTIL="not a date" build_archive
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(arch_state)" == "failed" ]]
  [[ "$(arch_reason)" == *"Valid-Until"* ]]
}

@test "archive: missing Valid-Until is accepted when the Date is fresh" {
  AR_UNTIL=none build_archive
  arch_run
  [[ "$(arch_state)" == "verified" ]]
}

@test "archive: signed Date older than the default 14 days -> not-verified" {
  AR_UNTIL=none AR_DATE="$(days_ago 40)" build_archive
  arch_run
  [[ "${status}" -eq 4 ]]
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == "signed index is older than 14 days" ]]
}

@test "archive: --max-index-age-days widens or narrows the window" {
  AR_UNTIL=none AR_DATE="$(days_ago 20)" build_archive
  arch_run --max-index-age-days 30
  [[ "$(arch_state)" == "verified" ]]
  arch_run --max-index-age-days 7
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == "signed index is older than 7 days" ]]
}

@test "archive: --max-index-age-days must be an integer from 1 to 365" {
  local v
  for v in 0 366 abc 1.5 -1 ""; do
    run "${TOOL}" --host t --path /usr/bin/chsh --max-index-age-days "${v}"
    [[ "${status}" -eq 3 ]]
  done
  run "${TOOL}" --host t --path /usr/bin/chsh --max-index-age-days
  [[ "${status}" -eq 3 ]]
}

@test "archive: signed Date more than a day in the future -> not-verified" {
  AR_UNTIL=none AR_DATE="$(days_ahead 3)" build_archive
  arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == "runner clock or index date is wrong"* ]]
}

@test "archive: missing or unparseable Date -> not-verified" {
  AR_UNTIL=none AR_DATE=none build_archive
  arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"Date"* ]]
  AR_UNTIL=none AR_DATE="garbage" build_archive
  arch_run
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"Date"* ]]
}

@test "archive: unknown mirror host without --keyring -> not-verified with reason" {
  build_archive
  run "${TOOL}" --host target1 --path /usr/bin/chsh --mirror https://mirror.example.invalid/debian
  [[ "${status}" -eq 4 ]]
  [[ "$(arch_state)" == "not-verified" ]]
  [[ "$(arch_reason)" == *"unknown archive host"* ]]
}

@test "archive: malformed suite from the target policy -> failed" {
  sed -i 's#trixie/main amd64 Packages#Tri$xie/main amd64 Packages#' "${MOCKDIR}/resp_meta"
  build_archive
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(arch_state)" == "failed" ]]
  [[ "$(arch_reason)" == *"malformed"* ]]
  ! grep -q '/dists/' "${MOCKDIR}/curl.log"
}

# ---- match fails closed ----

@test "archive: outside-verified match with a verified archive is match, exit 0" {
  build_archive
  arch_run --pve-host pve1 --ctid 123
  assert_success
  [[ "$(jq -r .verdict <<<"${output}")" == "match" ]]
  [[ "$(jq -r .trust <<<"${output}")" == "outside-verified" ]]
  [[ "$(arch_state)" == "verified" ]]
}

@test "archive: outside match with a not-verified archive is downgraded to match-unverified" {
  echo 404 >"${MOCKDIR}/ir_code"
  arch_run --pve-host pve1 --ctid 123
  [[ "${status}" -eq 4 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "match-unverified" ]]
  [[ "$(jq -r .trust <<<"${output}")" == "outside-read-unsigned-package" ]]
  [[ "$(jq -r .reason <<<"${output}")" == "archive signature not verified: "* ]]
  [[ "$(jq -r .sha256_outside <<<"${output}")" == "${PKG_SHA}" ]]
  arch_run --pve-host pve1 --ctid 123 --format md
  assert_output --partial "trust: **outside-read-unsigned-package**"
}

@test "archive: --no-archive-check keeps a clean outside match as match" {
  arch_run --pve-host pve1 --ctid 123 --no-archive-check
  assert_success
  [[ "$(jq -r .verdict <<<"${output}")" == "match" ]]
  [[ "$(arch_reason)" == "disabled by --no-archive-check" ]]
}

# ---- precedence (centralized in finish) ----

@test "archive: mismatch keeps precedence over a failed archive check" {
  write_ownership "$(sha_of tampered)"
  AR_STANZA_SHA="$(sha_of forged)" build_archive
  arch_run
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "mismatch" ]]
  [[ "$(arch_state)" == "failed" ]]
}

@test "archive: failed check plus outside mismatch is still mismatch" {
  write_outside "$(sha_of tampered)"
  AR_STANZA_SHA="$(sha_of forged)" build_archive
  arch_run --pve-host pve1 --ctid 123
  [[ "${status}" -eq 1 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "mismatch" ]]
  [[ "$(arch_state)" == "failed" ]]
}

@test "archive: failed check plus missing member is error, not package-unknown" {
  echo absent >"${MOCKDIR}/tar_mode"
  AR_STANZA_SHA="$(sha_of forged)" build_archive
  arch_run
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"archive signature check failed"* ]]
}

@test "archive: failed check plus outside failure names both in the error reason" {
  touch "${MOCKDIR}/ssh_fail_outside"
  AR_STANZA_SHA="$(sha_of forged)" build_archive
  arch_run --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"outside view requested but unavailable"* ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"archive signature check failed"* ]]
}

@test "archive: failed check beats an otherwise clean outside-verified match" {
  AR_STANZA_SHA="$(sha_of forged)" build_archive
  arch_run --pve-host pve1 --ctid 123
  [[ "${status}" -eq 3 ]]
  [[ "$(jq -r .verdict <<<"${output}")" == "error" ]]
  [[ "$(arch_state)" == "failed" ]]
  [[ "$(arch_reason)" == *"possible tampering"* ]]
  [[ "$(jq -r .reason <<<"${output}")" == *"possible tampering"* ]]
}

@test "archive: markdown shows the state and escapes the reason" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --keyring /nonexistent_ring.gpg --format md
  [[ "${status}" -eq 4 ]]
  assert_output --partial "Archive signature: not-verified"
  assert_output --partial 'nonexistent\_ring.gpg'
  build_archive
  arch_run --format md
  assert_output --partial "Archive signature: verified"
  assert_output --partial "${FPR_A^^}"
}

@test "archive: --keyring needs an absolute safe path" {
  run "${TOOL}" --host t --path /usr/bin/chsh --keyring 'rel/ring.gpg'
  [[ "${status}" -eq 3 ]]
  run "${TOOL}" --host t --path /usr/bin/chsh --keyring
  [[ "${status}" -eq 3 ]]
}

@test "archive: --version reports 1.4.0 and --help documents the new options" {
  run "${TOOL}" --version
  assert_output "package-verify 1.4.0"
  run "${TOOL}" --help
  assert_output --partial "--keyring"
  assert_output --partial "--no-archive-check"
  assert_output --partial "--max-index-age-days"
}
