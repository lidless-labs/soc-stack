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
    --max-time | --max-filesize | --proto | -w) shift 2 ;;
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
echo "$*" >>"${MOCKDIR}/dpkg-deb.log"
[[ "$1" == "-x" ]] || { echo "unexpected dpkg-deb mode: $1" >&2; exit 2; }
shift
[[ "$1" == "--" ]] && shift
dest="$2"
mkdir -p "${dest}/usr/bin"
cp "${MOCKDIR}/extract_content" "${dest}/usr/bin/chsh"
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
@@size
15
@@sha256
$1
@@end
EOF
}

@test "match: live equals package file, JSON output, exit 0" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  assert_success
  [[ "$(jq -r .verdict <<<"${output}")" == "match" ]]
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
  [[ "$(jq -r .sha256_outside <<<"${output}")" == "${PKG_SHA}" ]]
  [[ "$(jq -r .inputs.ctid <<<"${output}")" == "123" ]]
  grep -q outside "${MOCKDIR}/ssh.markers"
}

@test "markdown format emits a compact block with the verdict" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh --format md
  assert_success
  assert_output --partial "verdict: **match**"
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh
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

@test "dpkg-deb is only ever called with -x (never installs or runs scripts)" {
  run "${TOOL}" --host target1 --path /usr/bin/chsh
  assert_success
  run grep -v '^-x ' "${MOCKDIR}/dpkg-deb.log"
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
  run "${TOOL}" --host target1 --path /usr/bin/chsh
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
  for bad in 'pct mount' 'debugfs -w' 'apt-get install' 'dpkg -i' 'apt install' 'dpkg-deb -i'; do
    run grep -F -- "${bad}" "${TOOL}"
    [[ "${status}" -ne 0 ]] || { echo "found: ${bad}"; false; }
  done
}
