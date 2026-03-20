# Case: Adobe Acrobat Reader DC Remediation

**Case ID:** CASE-2026-0001
**Date:** 2026-02-05
**Status:** Resolved
**Severity:** Critical

## Summary

Wazuh vulnerability scan identified 703 CVEs on Windows 11 endpoint (Agent 031, 80-IT000907), with 208 rated Critical. Root cause: Adobe Acrobat Reader DC v15.007.20033 (from 2015) deployed via outdated GPO. Remediated via updated GPO deployment, eliminating 580 CVEs (82.5% reduction) and all 208 Critical vulnerabilities.

## Results

| Metric | Pre | Post | Change |
|--------|-----|------|--------|
| Total CVEs | 703 | 123 | -580 (82.5%) |
| Critical | 208 | 0 | -208 (100%) |
| High | 326 | 86 | -240 (73.6%) |
| Medium | 107 | 37 | -70 (65.4%) |
| Low | 16 | 0 | -16 (100%) |

## Evidence

Original evidence in `cases/2026-02-05_windows11-cve-remediation/evidence/`:
- `pre-remediation-vulnerabilities.csv` (703 CVEs)
- `post-remediation-vulnerabilities.csv` (123 CVEs)
- `post-dashboard-overview.jpg`
- `post-critical-zero-filtered.jpg`
- `post-high-severity-filtered.jpg`

## Playbook Used

`playbooks/vulnerability-remediation-software.md`

## Remaining

- Windows 11 OS cumulative update (116 CVEs)
- Microsoft Teams removal via GPO (7 CVEs)
