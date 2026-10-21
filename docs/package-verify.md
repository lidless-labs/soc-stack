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

Exit codes: `0` match (outside-verified), `1` mismatch, `2` package-unknown,
`3` error or usage, `4` match-unverified (self-reported only).

## Canonical paths

`--path` must already be canonical. The tool asks the target for
`readlink -f` of the path and returns `error` ("pass the canonical path
(target resolves it to X)") when the answer differs. On Debian, `/bin` is a
symlink to `/usr/bin`, so pass `/usr/bin/passwd`, not `/bin/passwd`. The outside
view always reads the path you supplied, never a path the target reported.

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
   `error`; no entry is `package-unknown`). The file is then hashed by
   streaming it with `tar -xOf -`. The package is untrusted data: nothing is
   installed and nothing from it is executed. If the pool no longer has the
   version on a Debian archive, `snapshot.debian.org` is tried.
4. Outside view (with `--pve-host` and `--ctid`): on the Proxmox host,
   `pct config` to find the rootfs volume and `pvesm path` to resolve it. Only a
   block device is read, with read-only `debugfs` (no `-w`): `stat` must show a
   regular file, then `cat` is hashed. A directory-backed rootfs is not read at
   all (following a container-controlled symlink from the hypervisor would be
   unsafe); the outside value is `null` with the reason "unsupported rootfs type
   (directory-backed); outside view not taken". The container is never mounted.
   A block-device read of a running container can lag the page cache.
5. Verdict, see below.

## Verdicts and trust

| Verdict | Exit | Meaning | `trust` |
| --- | --- | --- | --- |
| `match` | 0 | outside hash equals inside hash equals package file hash | `outside-verified` |
| `match-unverified` | 4 | inside hash equals package file hash, no independent outside view | `self-reported` |
| `mismatch` | 1 | any compared hash differs | as available |
| `package-unknown` | 2 | not owned, diverted, version or file not in the archive, unsupported origin | as available |
| `error` | 3 | see above | as available |

`match` needs an independent outside (hypervisor) hash. Without one, every
fact (the resolved path, the owning package, its version, the .deb checksum and
the live hash) comes from the target, so a compromised target can forge a
clean-looking result. `match-unverified` and `trust: "self-reported"` mean the
result rests entirely on the target's honesty.

## Output

JSON includes the tool version, UTC timestamp, inputs (host labels as given),
package, version, architecture, origin, `deb_url`, `deb_sha256` and whether it
matched the apt metadata, the inside, extracted and outside SHA-256 values (the
outside value is `null` plus a reason when there is no outside view), the
verdict, `trust`, and `archive_signature: "not-verified"`. In Markdown output,
target-controlled text is reduced to printable ASCII, truncated to 200
characters and Markdown-escaped before it is rendered.

## Trust limits

- The InRelease/Packages GPG signature is not checked by this tool
  (`archive_signature: "not-verified"`). The .deb is bound to the SHA256 the
  target reports from its apt lists, which a compromised target can forge.
  Independent verification needs a Debian keyring on the runner (for example
  `debian-archive-keyring`); the tool never installs one and that remains
  pending the owner's approval.
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
