# Gotchas

Consolidated from production deployments. If a script doesn't handle one of these, it's a bug.

## Hyper-V / VM Creation

### VHDX Sparse File Attribute (Showstopper)
**Symptom:** `Start-VM` or `Resize-VHD` fails with error `0xC03A001A: Virtual hard disk files must be uncompressed and unencrypted and must not be sparse.`

**Cause:** `qemu-img convert` creates VHDX files with the NTFS sparse attribute.

**Fix:** Remove sparse flag BEFORE any Hyper-V operations:
```powershell
fsutil sparse setflag "<path>.vhdx" 0
```

**Order matters:** sparse removal -> resize -> permissions -> create VM. `create-vm.ps1` handles this automatically.

### Cloud-Init Network Config for Hyper-V
**Symptom:** VM boots but never gets an IP address.

**Cause:** Ubuntu cloud images don't auto-configure networking on Hyper-V. The NIC uses the `hv_netvsc` driver.

**Fix:** Include a `network-config` file in the cloud-init ISO that matches by driver:
```yaml
version: 2
ethernets:
  id0:
    match:
      driver: hv_netvsc
    dhcp4: true
```

Using `match: driver: hv_netvsc` is more reliable than hardcoding `eth0`. The `cloud-init/base-network-config.yaml` template handles this.

### Hyper-V Guest IP Reporting
**Symptom:** `(Get-VMNetworkAdapter <vm>).IPAddresses` returns empty.

**Cause:** Hyper-V needs `linux-tools-virtual`/`hyperv-daemons` for guest integration. Cloud images don't have them.

**Workaround:** Use ARP scan: `arp -a | grep "00-15-5d"`. The `find-vm-ip.ps1` script automates this.

### Cloud-Init Only Runs Once
If cloud-init finishes (even with errors), it won't re-run on reboot. To retry: delete the VM, delete the VHDX, reconvert from the original cloud image. No shortcuts.

### Elevated PowerShell Required
All Hyper-V commands and `fsutil` need admin elevation. Run scripts as Administrator.

### Don't Batch Hyper-V PowerShell Commands
Running multiple Hyper-V cmdlets in rapid succession causes intermittent failures. `create-vm.ps1` runs them one at a time with error checking.

## TheHive

### Password Change Endpoint
**Symptom:** `PATCH /api/v1/user/<login>` with `{"password":"..."}` returns 204 but password doesn't change.

**Cause:** The PATCH endpoint silently ignores the password field.

**Fix:** Use `POST /api/v1/user/<login>/password/change` with `{"currentPassword":"old","password":"new"}`.

### TheHive Startup Time
TheHive takes 30-60 seconds to start. It waits 30s for Cassandra internally, then generates config from CLI args. Poll the health endpoint rather than using fixed sleeps.

## Cortex

### CSRF Protection (The Big One)
**Symptom:** All POST/PUT/PATCH/DELETE requests return 403 Forbidden after login.

**Cause:** Cortex uses Elastic4Play's custom CSRF filter. The cookie and header names are non-standard and buried in `reference.conf`:
- Cookie: `CORTEX-XSRF-TOKEN`
- Header: `X-CORTEX-XSRF-TOKEN`

**Fix:** After login, make any GET request to receive the CSRF cookie. Send it back as both a cookie AND the header on all mutating requests. Or use `Authorization: Bearer <key>` which bypasses CSRF entirely.

Standard Play Framework CSRF bypass headers (`Csrf-Token: nocheck`, `X-CSRF-TOKEN`, etc.) do NOT work.

### First User Creation is One-Shot
The `POST /api/user` endpoint without auth only works when zero users exist. After the first user is created, all user management requires auth + CSRF.

## MISP

### MariaDB OOM on Small VMs
**Symptom:** MariaDB container restarts with `Out of memory (Needed 2587885448 bytes)`.

**Cause:** Default InnoDB buffer pool is 2GB.

**Fix:** Set `INNODB_BUFFER_POOL_SIZE=512M` for 4GB VMs. Also `docker compose down -v` to wipe the failed DB volume before restarting.

| VM RAM | INNODB_BUFFER_POOL_SIZE |
|--------|------------------------|
| 4GB    | 512M                   |
| 8GB    | 2048M                  |
| 16GB   | 4096M                  |

### Advanced Authkeys
MISP has advanced authkeys enabled by default. Use the cake CLI to generate keys:
```bash
docker compose exec misp-core bash -c \
  "cd /var/www/MISP/app && php cake user change_authkey admin@misp.local"
```

## General

### Docker Compose v2, Not v1
Install Docker Compose as a CLI plugin (`docker compose`), not the standalone Python package (`docker-compose`). The cloud-init templates handle this correctly.

### Bash Special Characters in Passwords
Passwords with `!` break curl JSON due to bash history expansion. Always use `printf '...' | curl -d @-` instead of `-d '{"password":"Foo!"}'`.
