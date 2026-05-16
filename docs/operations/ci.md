# CI setup

soc-stack's CI runs in three layers:

| Layer | Where | Trigger | Catches |
|---|---|---|---|
| Shellcheck + bashate | GitHub Actions (ubuntu-latest) | every PR | syntax, unquoted vars, missing `set -euo pipefail` |
| Bats unit tests (mocked `pct`/`qm`/`docker`) | GitHub Actions (ubuntu-latest) | every PR | shared lib logic, state machine, JSON schemas |
| Integration tests on real LXCs | Self-hosted runner LXC on a test Proxmox host | every PR + merge to main | end-to-end |

## First-time runner setup

On the Proxmox test host, as root:

```bash
# 1. Get a runner registration token from the GitHub UI:
#    https://github.com/solomonneas/soc-stack/settings/actions/runners/new
#    (Token expires in 1 hour; generate just before running setup.)

# 2. Clone the repo if not already present
git clone https://github.com/solomonneas/soc-stack.git /root/soc-stack
cd /root/soc-stack

# 3. Run the bootstrap
export GITHUB_RUNNER_TOKEN=<token-from-step-1>
sudo -E bash tools/setup-ci-runner.sh
```

Effect:
- Creates LXC `gh-runner-soc-stack` (VMID 119 by default; override with `RUNNER_VMID=N`)
- Generates an SSH key inside the LXC and authorizes it for a new `gh-runner` user on the Proxmox host
- Sudoers entry scoping `gh-runner` to `pct`, `qm`, `pvesm`, `pveam` only
- Installs github-actions-runner inside the LXC and registers it with labels `[self-hosted, soc-stack, proxmox]`
- Drops `/etc/cron.d/soc-stack-test-reaper` that destroys test LXCs (VMID 9000-9099) older than 90 minutes

## Verify the runner is online

```bash
gh api repos/solomonneas/soc-stack/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Expect to see one runner named `soc-stack-proxmox-host` (or your equivalent) with `status: "online"` and the three labels.

## Replacing the runner token

Tokens are one-shot. If you need to re-register (e.g., after wiping the LXC):

```bash
# Inside the runner LXC:
cd /home/runner/actions-runner
sudo -u runner ./svc.sh stop
sudo -u runner ./config.sh remove --token <removal-token-from-github-ui>
# Then re-run setup-ci-runner.sh on the Proxmox host with a new registration token.
```

## Resource budget

- Runner LXC: 4 GB RAM, 30 GB disk, 2 cores
- Test LXCs (peak): ~12 GB RAM across all 6 components at `--preset minimal`
- Total CI footprint at peak: ~16 GB RAM, ~150 GB disk

For proxmox-host (32 GB total), this fits as long as no more than one test run is active. The CI workflow uses a `concurrency` group `soc-stack-integration` to enforce serial execution across PRs.

## Manual reap

If the cron misses something or you want to force-clean:

```bash
ssh root@<proxmox-host> "pct list | awk 'NR>1 && \$1 >= 9000 && \$1 <= 9099 {print \$1}' | xargs -r -I{} bash -c 'pct stop {} 2>/dev/null; pct destroy {} 2>/dev/null'"
```
