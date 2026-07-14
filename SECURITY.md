# Security Posture

SOC Stack deploys security tooling, so it should be honest about its own security model. This document describes what the installer hardens, what it deliberately accepts, and where the line is.

## Threat model

SOC Stack assumes:

- **A trusted Proxmox host.** The installer runs as root on the host and creates LXCs. Anyone who can run it already owns the box.
- **A trusted internal bridge.** Components talk to each other over the Proxmox bridge (default `vmbr0`). Traffic between LXCs is assumed to stay on hardware you control.
- **Root-only state.** Everything sensitive lives under `/var/lib/soc-stack/` and `/root/` with root-only permissions.

It is built for homelabs, training labs, and internal SOC replication. It is **not** hardened for deployment on a network where other tenants or untrusted users can reach the component IPs. If you need that, put the stack behind a firewall/VLAN and add TLS termination in front of the HTTP services.

## What the installer hardens

- **Default credentials are rotated and verified.** TheHive (`admin@thehive.local` / `secret`) and MISP (`admin@admin.test` / `admin`) ship with upstream defaults; deploy rotates them to random values and fails the component if rotation cannot be verified. Wazuh, Cortex, MariaDB, and LXC root passwords are generated per install.
- **Secrets on disk are root-only.** Generated credentials live in `/var/lib/soc-stack/secrets/` (dir `0700`, files `0600`, written under `umask 0077`). State files and the emitted JSON are `0600`.
- **Result JSON is redacted by default.** `/root/soc-stack.json` replaces passwords/tokens/keys with `REDACTED` and lists secret file paths instead. `--include-secrets-json` opts into raw values for automation that needs them.
- **MCP servers bind to 127.0.0.1 by default and require a bearer token.** Each SSE endpoint is fronted by an nginx gateway that rejects any request whose `Authorization` header is not that server's exact bearer token (`mcp-proxy` has no auth of its own, so the gateway enforces it). Those tokens have admin-level reach into every component. `--mcp-bind-host 0.0.0.0` exposes the endpoints to the network; they stay token-gated and the installer records a warning, but only do that on a network where you trust every host. `/root/mcp-clients.json` contains the bearer tokens and is written `0600`.
- **MCP server code is pinned.** The 9 MCP server repos are cloned at pinned commit SHAs, so upstream changes (or a compromised repo) cannot silently alter what gets deployed.
- **Services run with systemd hardening** (`NoNewPrivileges`, `PrivateTmp`, `ProtectHome`, kernel protections) where the workload allows it.

## What is deliberately accepted

These are known trade-offs under the threat model above, not oversights:

- **Plain HTTP between components.** TheHive (9000), Cortex (9001), and the dashboards serve HTTP on the internal bridge. Adding self-signed TLS everywhere would mostly add `-k` flags, not security, on a single-host bridge. MISP and Wazuh serve HTTPS with self-signed certificates.
- **`curl -k` against localhost.** Health checks and API calls inside an LXC talk to `https://localhost` with self-signed certs; verification is skipped because there is nothing meaningful to verify.
- **Secrets exist in plaintext on the host.** `/var/lib/soc-stack/secrets/` is the recovery story. If your root filesystem is compromised, these files are the least of your problems, but know they are there before imaging or backing up the host.
- **The `curl | sudo bash` install.** Convenient, and exactly as trustworthy as the repo it fetches. If that bothers you (reasonable), clone the repo, read `install.sh`, and run it locally; the behavior is identical.

## What you should do after install

1. Keep the stack off untrusted networks, or firewall the component IPs to your management subnet.
2. Treat `/root/soc-stack.json`, `/root/mcp-clients.json`, and `/var/lib/soc-stack/secrets/` as credential material in backups.
3. If you exposed MCP with `--mcp-bind-host 0.0.0.0`, rotate the bearer tokens if you ever suspect a host on that network.
4. Update components on your own schedule; the installer pins versions and does not auto-update anything.

## Reporting a vulnerability

Open a GitHub issue for anything that does not leak a secret, or use GitHub's private vulnerability reporting on this repository for anything that does.
