## Summary
<!-- 1-3 bullets describing what this PR changes -->

## Component (if applicable)
<!-- e.g., wazuh, mcp, dashboards, or "lib" / "orchestrator" / "ci" -->

## Test plan
- [ ] Bats unit tests pass (`./tests/unit/run.sh`)
- [ ] Shellcheck clean
- [ ] Integration assertion passes on the self-hosted Proxmox runner (if touching a component or lib)
- [ ] No em-dashes in commit messages or files
- [ ] No `Co-Authored-By` trailers
- [ ] No leaked PII, secrets, real private IPs, hostnames, or `/home/<user>` paths (documentation IPs use the RFC 5737 range; real values are scrubbed)

## Related
<!-- Closes #N, refs #N, or "n/a" -->
