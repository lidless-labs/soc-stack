# Roadmap

GitHub issues are the source of truth for filed work. This file lists what is
active, what is next, and what stays deferred so README claims and open issues
stay aligned. Completed and abandoned items live in
[docs/roadmap-archive.md](docs/roadmap-archive.md).

## Active

Correctness and reliability bugs queued for the next fix slice:

- [#7](https://github.com/lidless-labs/soc-stack/issues/7) do not continue with a nonexistent Ubuntu template after download failure
- [#9](https://github.com/lidless-labs/soc-stack/issues/9) integration assertions cannot authenticate against the redacted result JSON
- [#10](https://github.com/lidless-labs/soc-stack/issues/10) validate static networking semantically in flag and manifest modes
- [#11](https://github.com/lidless-labs/soc-stack/issues/11) honor explicitly supplied default-valued manifest overrides
- [#12](https://github.com/lidless-labs/soc-stack/issues/12) result JSON reports skipped or soft-failed integrations as success
- [#14](https://github.com/lidless-labs/soc-stack/issues/14) align Proxmox version enforcement, error text, and tests

## Next

Enhancement backlog and smaller chores sized for single implementation slices:

- [#8](https://github.com/lidless-labs/soc-stack/issues/8) harden the documented remote installer (checksums, pinned versions, correct org)
- [#16](https://github.com/lidless-labs/soc-stack/issues/16) export a MITRE ATT&CK Navigator coverage layer for the deployed stack
- [#17](https://github.com/lidless-labs/soc-stack/issues/17) opt-in post-install continuous health report
- [#18](https://github.com/lidless-labs/soc-stack/issues/18) review and close the stale June operator report
- [#19](https://github.com/lidless-labs/soc-stack/issues/19) move obsolete Hyper-V guidance out of installer gotchas

## Deferred

Large or cross-cutting work. Open or extend a GitHub issue before starting:

- [#13](https://github.com/lidless-labs/soc-stack/issues/13) make MCP verification end-to-end (active units, authenticated SSE, real log transport)
- OpenCTI component (deferred to v2 per design spec; no issue filed)
- Multi-host / multi-node Proxmox deployment (README states out of scope today; no issue filed)
- Ansible or Terraform rewrite of the installer (README teaser; no issue filed)

Permanent product boundaries — not roadmap items:

- Not a hardened production SOC (see [SECURITY.md](SECURITY.md))
- Not security-efficacy testing (verify services integrate, not that detections catch threats)
- Not an auto-updater for running components in place
