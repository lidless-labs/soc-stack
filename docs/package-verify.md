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
| `--path` | absolute path; only `A-Za-z0-9._+/-`, no `..` |
| `--pve-host`, `--ctid` | add the outside read of the container root filesystem |
| `--inside-via-pct` | run the inside commands with `pct exec` on `--pve-host` |
| `--format json\|md` | JSON (default) or a compact Markdown block |
| `--mirror <url>` | archive base URL; default is derived from the target's apt origin |

Exit codes: `0` match, `1` mismatch, `2` package-unknown, `3` error or usage.

## What it does

1. Validates every argument against a strict allowlist before any remote use,
   and runs ssh with `BatchMode=yes`. Scripts are sent on stdin; arguments are
   shell-quoted.
2. On the target: `readlink -f`, `dpkg -S` (owner), `dpkg-divert` (a diverted
   path yields `package-unknown`), `dpkg-query` (exact version and architecture),
   `sha256sum` of the live file, `apt-cache show pkg:arch=version` (the
   `Filename:` and `SHA256:` of the .deb from the target's own GPG-verified apt
   lists) and `apt-cache policy` (the archive origin).
3. On the runner: downloads exactly that .deb from the archive into a `mktemp
   -d` directory (removed on exit), requires its SHA-256 to equal the target's
   apt `SHA256:` (otherwise the verdict is `error`, never `match`), extracts it
   with `dpkg-deb -x` and hashes the file at the resolved path. The package is
   untrusted data: nothing is installed, no maintainer script runs, nothing from
   it is executed. If the pool no longer has the version on a Debian archive,
   `snapshot.debian.org` is tried.
4. Outside view (with `--pve-host` and `--ctid`): on the Proxmox host,
   `pct config` to find the rootfs volume, `pvesm path` to resolve it, then
   `debugfs -R "cat <path>"` for a block device or image (read-only, no `-w`)
   or `sha256sum` for a directory-backed rootfs. It never mounts the container.
   A block-device read of a running container can lag the page cache.
5. Verdict: `match`, `mismatch`, `package-unknown` or `error`.

## Output

JSON includes the tool version, UTC timestamp, inputs (host labels as given),
package, version, architecture, origin, `deb_url`, `deb_sha256` and whether it
matched the apt metadata, the inside, extracted and outside SHA-256 values (the
outside value is `null` plus a reason when there is no outside view), the
verdict, and `archive_signature: "not-verified"`.

## Trust limits

- The InRelease GPG signature is not checked by this tool. Trust in the .deb
  rests on the target's apt-verified metadata (apt already verified the
  signature chain down to the `SHA256:` it reports) plus the independent
  outside read. Checking the signature independently needs a Debian keyring on
  the runner, and the tool never installs packages.
- A host that is fully compromised can lie to every command run on it. For
  containers, the outside view reads the root filesystem from the hypervisor
  without using the container's own tools. A hypervisor has no outside view.
- Third-party repositories and locally built packages return `package-unknown`;
  pass `--mirror` only for an archive you trust.

## Tests

`tests/unit/test_package_verify.bats` mocks `ssh`, `curl` and `dpkg-deb`, so it
needs no network or host. Run it through `./scripts/verify`.
