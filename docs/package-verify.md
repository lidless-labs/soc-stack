# package-verify: check a file against its distro package

`tools/package-verify.sh` answers one question for a Debian or Ubuntu host:
is this file byte-identical to the file in the official package that owns it?
It exists to settle rootkit-scanner "trojaned binary" findings (for example a
Wazuh rootcheck signature hitting `/usr/bin/passwd`) with evidence instead of a
guess. It is strictly read-only on every machine it touches.

## Usage

```bash
# Host reachable over ssh
tools/package-verify.sh --host <ssh-target> --path /usr/bin/passwd

# Container on a Proxmox host, with an independent outside read
tools/package-verify.sh --inside-via-pct --pve-host <pve-ssh-target> --ctid <id> \
  --path /usr/bin/passwd

# Container with its own sshd, plus the outside read, as a TheHive comment
tools/package-verify.sh --host <ct-ssh-target> --path /usr/bin/passwd \
  --pve-host <pve-ssh-target> --ctid <id> --format md
```

| Flag | Meaning |
| --- | --- |
| `--host` | ssh target that holds the file (optional with `--inside-via-pct`) |
| `--path` | absolute canonical path; only `A-Za-z0-9._+/-`, no `..` |
| `--pve-host`, `--ctid` | add the outside read of the container root filesystem |
| `--inside-via-pct` | run the inside commands with `pct exec` on `--pve-host` |
| `--format json\|md` | JSON (default) or a compact Markdown block |
| `--mirror <url>` | https archive base URL; default is derived from the target's apt origin |
| `--keyring <path>` | GPG keyring for the archive signature check; default `/usr/share/keyrings/debian-archive-keyring.gpg` or `ubuntu-archive-keyring.gpg`, chosen from the archive host (an unknown host needs `--keyring`) |
| `--no-archive-check` | skip the archive signature check |

Exit codes: `0` match (outside-verified), `1` mismatch, `2` package-unknown,
`3` error or usage, `4` match-unverified (self-reported only).

## Canonical paths

`--path` must already be canonical. The tool asks the target for
`readlink -f` of the path and returns `error` ("pass the canonical path
(target resolves it to X)") when the answer differs. On Debian, `/bin` is a
symlink to `/usr/bin`, so pass `/usr/bin/passwd`, not `/bin/passwd`. The outside
view always reads the path you supplied, never a path the target reported.

On Debian 12 and other usrmerged systems dpkg may register a file as
`/bin/ls` while the real path is `/usr/bin/ls`, and the .deb ships `./bin/ls`.
When `dpkg -S` finds nothing for the canonical path, the tool tries the
usrmerge alias (`/usr/bin` <-> `/bin`, `/usr/sbin` <-> `/sbin`,
`/usr/lib*` <-> `/lib*`). The dpkg-registered path is used as the package
member and is reported as `dpkg_path` in the JSON; the inside hash and the
outside view keep using the canonical path. A dpkg path that is neither the
canonical path nor its alias is an `error`. The alias is accepted only when
`readlink -f` of the alias on the target resolves to the canonical path;
otherwise the alias is ignored and the file counts as not owned
(`package-unknown`). A dpkg diversion on the alias path
(`dpkg-divert --truename` or `--listpackage`) is treated like a diversion on
the canonical path (`package-unknown`).

## What it does

1. Validates every argument against a strict allowlist before any remote use,
   and runs ssh with `BatchMode=yes`. Scripts are sent on stdin; arguments are
   shell-quoted.
2. On the target: `readlink -f` (must equal `--path`), `dpkg -S` (owner),
   `dpkg-divert` (a diverted path yields `package-unknown`), `dpkg-query`
   (exact version and architecture), `sha256sum` of the live file,
   `apt-cache show pkg:arch=version` (the `Filename:` and `SHA256:` of the .deb
   from the target's own apt lists) and `apt-cache policy` (the archive origin).
3. On the runner: downloads exactly that .deb into a `mktemp -d` directory
   (removed on exit) with `curl` restricted to https (also for redirects), a
   200 MB size cap and a timeout. It requires the .deb SHA-256 to equal the
   target's apt `SHA256:` and requires `dpkg-deb -f` to report the same
   Package, Version and Architecture the target claimed; either failure is
   `error`, never `match`. Nothing is extracted to disk. The member list comes
   from `dpkg-deb --fsys-tarfile | tar -tvf -` and must contain exactly one
   entry for `./<path>` that is a regular file (a symlink or hardlink entry is
   `error`; no entry is `package-unknown`). The listing is filtered as a
   stream and never stored: the reader stops after two matches, which already
   proves "not exactly one" (a hardlink or symlink error names the link
   target so you can verify that path instead). The file is then hashed by
   streaming it with `tar -xOf -`. Every decoder and parser stage
   (`dpkg-deb -f`, `dpkg-deb --fsys-tarfile`, `tar`, and the listing filter)
   runs under a timeout (`PV_DECODER_TIMEOUT`, 1 to 3600 seconds, default 120)
   and a virtual memory cap (`PV_DECODER_VMEM_KB`, 262144 to 8388608, default
   1048576, i.e. 1 GiB). Out-of-range or non-numeric values exit 3, and a
   memory cap that cannot be applied is an error rather than a silent
   no-op. `dpkg-deb --fsys-tarfile` always runs with `--threads-max=1`: the
   multithreaded xz decoder in dpkg-deb 1.22 reserves per-thread address space
   that exceeds the 1 GiB cap on large multi-block packages ("lzma error:
   Cannot allocate memory"). Control-field output is capped at 4 KiB. The tar
   listing is clipped to 2048 bytes per line before the filter sees it, and the
   filter emits only bounded fields (type, size, member name up to 512 bytes,
   link target up to 256 bytes), so a crafted PAX link target cannot exhaust
   memory. A decompression bomb inside the 200 MB download ends as `error`,
   not as a hang or an out-of-memory runner. The package is untrusted data: nothing is
   installed and nothing from it is executed. If the pool no longer has the
   version on a Debian archive, `snapshot.debian.org` is tried.
4. Outside view (with `--pve-host` and `--ctid`): on the Proxmox host,
   `pct config` to find the rootfs volume and `pvesm path` to resolve it. Only a
   block device is read, with read-only `debugfs` (no `-w`): `stat` must show a
   regular file, then `cat` is read once and that single stream is hashed and
   counted together, so a partial read cannot pair a hash with the count of a
   different, complete read. The
   script runs under `bash` with `pipefail`, so a failed or timed-out read is
   an `@@error`, and the runner accepts the hash only if the byte count equals
   the size `debugfs stat` reports (a failed read often exits 0 and yields the
   hash of empty input). The live file gets the same check: the empty-input
   hash with a non-zero size is an `error`, and a size that differs from the
   package member while the hashes agree is an `error`. If the hashes differ,
   the result is a real `mismatch` regardless of size. A directory-backed rootfs is not read at
   all (following a container-controlled symlink from the hypervisor would be
   unsafe); the outside value is `null` with the reason "unsupported rootfs type
   (directory-backed); outside view not taken". The container is never mounted.
   A block-device read of a running container can lag the page cache.
   An unreachable Proxmox host or a failed outside read is an `error`, unless
   the inside hash already differs from the package file: a mismatch always
   wins, and the outside failure is recorded in the reason and in
   `sha256_outside_reason`.
5. Archive signature check (after the .deb SHA-256 equals the target's apt
   `SHA256:`, skipped with `--no-archive-check`). The suite, component and index
   architecture come from the `apt-cache policy` origin line (for example
   `trixie/main amd64`) and are validated before they are used in a URL. The
   runner fetches `dists/<suite>/InRelease` over https (1 MiB cap) and verifies
   it with `gpgv --status-fd`, parsing only the machine status lines. The policy
   is stricter than apt's. `verified` needs at least one `VALIDSIG` from the
   keyring and none of the following. Any `BADSIG`, `EXPKEYSIG`, `REVKEYSIG`
   or `EXPSIG` is `failed`. A gpgv exit status other than 0 or 2 (a timeout or
   kill), any `NODATA` or `FAILURE`, or an `ERRSIG` with a reason other than 9
   (missing key) is `not-verified`. With no `VALIDSIG` (only reason-9 `ERRSIG`
   and `NO_PUBKEY`, or no status lines) the result is `not-verified` with "no
   signature from a key in <keyring>; the keyring may be stale". Signatures by
   keys missing from the keyring are tolerated next to a valid one, which
   matters because Debian signs with several keys and an older keyring package
   can know only some of them; gpgv then exits 2. The fingerprints of the valid signers are recorded.
   Only the plaintext that gpgv writes is read afterwards, never the raw
   InRelease. Freshness: a past `Valid-Until` or an unparseable one is `failed`. Debian main
   InRelease carries no `Valid-Until`, so it is not required; instead the
   signed `Date` must be parseable, not older than `--max-index-age-days`
   (default 120, 1 to 365) and not more than one day in the future, else
   `not-verified`. The SHA-256 and size of
   `<component>/binary-<arch>/Packages.xz` (or `.gz`) are taken from the signed
   text; the index is fetched (from `by-hash/SHA256/<hash>` when the release
   declares `Acquire-By-Hash: yes`, 128 MiB cap) and must match both. A mismatch is `failed` when the index was fetched by hash;
   from the plain path it is `not-verified` ("index changed during fetch
   (mirror mid-sync) or was altered"), since a mirror can be mid-sync. It is
   decompressed under the same time and memory bounds as the package decoders
   and stream-parsed for the stanza with the target's package, version and
   architecture; its `SHA256` and `Filename` must equal the target's apt
   `SHA256` and `Filename`. This check uses `gpgv` and `xz` (or `gzip`) plus a
   keyring on the runner. They are optional: when one is missing the result is
   `not-verified` with a reason and the run never errors for that.
6. Verdict, see below.

## Verdicts and trust

| Verdict | Exit | Meaning | `trust` |
| --- | --- | --- | --- |
| `match` | 0 | outside hash equals inside hash equals package file hash, and `archive_signature` is `verified` (or `--no-archive-check` was given) | `outside-verified` |
| `match-unverified` | 4 | inside hash equals package file hash with no outside view, or the outside view agrees but the archive signature is not verified | `self-reported`, or `outside-read-unsigned-package` |
| `mismatch` | 1 | any compared hash differs | as available |
| `package-unknown` | 2 | not owned, diverted, version or file not in the archive, unsupported origin | as available |
| `error` | 3 | usage error, missing runner command (`jq curl dpkg-deb tar ssh sha256sum timeout`), ssh failure, download network failure (curl 000 or HTTP 5xx; a 404 stays `package-unknown`), integrity check failure, incomplete or inconsistent read, decoder timeout, failed archive signature check | as available |

`match` needs an independent outside (hypervisor) hash. Without one, every
fact (the resolved path, the owning package, its version, the .deb checksum and
the live hash) comes from the target, so a compromised target can forge a
clean-looking result. `match-unverified` and `trust: "self-reported"` mean the
result rests entirely on the target's honesty.

Archive signature rules. A final `match` (exit 0) requires
`archive_signature: "verified"`. If the archive check was on and ended
`not-verified`, an otherwise clean outside-verified result is downgraded to
`match-unverified` (exit 4) with the reason "archive signature not verified:
<reason>" and trust `outside-read-unsigned-package`: the outside read agrees
with the .deb, but the .deb is vouched for only by the target's apt metadata.
With `--no-archive-check` the v1.3 behavior stays: a clean outside-verified
result is `match`, and the JSON says `not-verified` with the reason "disabled
by --no-archive-check". A `failed` check (including malformed suite, component
or architecture in the target's policy line, which is target-controlled data)
turns every verdict except `mismatch` into `error` (exit 3), for example a
`package-unknown` caused by a missing member, and an error that was already
being reported also names the archive failure. `mismatch` always wins. A target
with no parsable apt origin at all still gets `package-unknown` earlier.

A superseded version (one no longer in the current signed index) only reaches
the archive check when the target's apt lists are older than the archive. With
current lists the target has no entry for it and the result is `package-unknown`
before any download.

## Output

JSON includes the tool version, UTC timestamp, inputs (host labels as given),
package, version, architecture, origin, `deb_url`, `deb_sha256` and whether it
matched the apt metadata, the inside, extracted and outside SHA-256 values (the
outside value is `null` plus a reason when there is no outside view), the
verdict, `trust`, `dpkg_path` (the path dpkg registered, which differs from
`resolved_path` only for a usrmerge alias), and the archive result:
`archive_signature` (`verified`, `not-verified` or `failed`) with
`archive_signature_detail` (`suite`, `component`, `index`,
`signer_fingerprints`, `reason`). In Markdown output,
target-controlled text is reduced to printable ASCII, truncated to 200
characters and Markdown-escaped before it is rendered.

## Trust limits

- `archive_signature: "verified"` means the runner itself checked the archive
  signature and found the .deb in the signed index, so a compromised target
  cannot forge the binding between the .deb and its checksum. It says nothing
  about the live file; only the outside view does.
- `not-verified` covers (it does not change the verdict by itself, but it
  blocks a final `match`, see above): `--no-archive-check`, no `gpgv`, a stale or future-dated signed index,
  a signature only by keys missing from the keyring, gpgv errors,
  `xz`/`gzip` or keyring on the runner, an unknown archive host without
  `--keyring`, a .deb fetched from `snapshot.debian.org`, a package version
  that is no longer in the current signed index (superseded by an update), and
  a network failure or non-200 on InRelease or the index. In those cases the
  .deb is bound only to the SHA256 the target reports from its apt lists, which
  a compromised target can forge.
- Debian stable and oldstable main `InRelease` files are re-signed only at point
  releases, so their `Date` can be weeks or months old (trixie main was dated
  2026-09-12 when checked in late October) while `-security` and `-updates` are
  refreshed daily. The default `--max-index-age-days` is therefore 120. A
  replayed older signed index can only vouch for an older genuine package, so
  the residual risk is narrow, and suites that carry `Valid-Until` are still
  governed by it. If two point releases are ever more than 120 days apart, stable
  main packages become `not-verified` (and a clean outside match is downgraded
  to `match-unverified`) until the next point release, unless you pass a larger
  value.
- `failed` (verdict `error`) covers a bad, expired-key or revoked-key
  signature, no valid signature at all, an expired `Valid-Until`, an index whose
  size or hash differs from the signed text, and a signed stanza that
  disagrees with the target's apt `SHA256` or `Filename`.
- The default Debian keyring package on the runner can lag the archive: the
  Ubuntu `debian-archive-keyring` 2023.4 knows the bookworm keys but not the
  trixie ones, and trixie InRelease is still accepted because one of its
  signatures is by a known key. Keep the keyring package current.
- A host that is fully compromised can lie to every command run on it. For
  containers on a block-device rootfs, the outside view reads the file from the
  hypervisor without using the container's own tools, and is the only
  independent evidence. A hypervisor has no outside view, so its best verdict
  is `match-unverified`.
- Third-party repositories and locally built packages return `package-unknown`;
  pass `--mirror` only for an https archive you trust.

## Tests

`tests/unit/test_package_verify.bats` mocks `ssh`, `curl` and `dpkg-deb` (real
`tar` builds the archives), so it needs no network or host. Run it through
`./scripts/verify`.
