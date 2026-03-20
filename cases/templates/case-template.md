# Case: [TITLE]

**Case ID:** [CASE-YYYY-NNNN]
**Date:** [YYYY-MM-DD]
**Analyst:** [Name]
**Status:** Open | In Progress | Resolved | Closed
**Severity:** Critical | High | Medium | Low

## Summary

Brief description of the incident, what triggered it, and the outcome.

## Timeline

| Time | Event |
|------|-------|
| YYYY-MM-DD HH:MM | Initial detection |
| | Investigation started |
| | Root cause identified |
| | Remediation applied |
| | Verification complete |

## Detection

**Source:** Wazuh | Suricata | Zeek | Manual
**Alert/Rule:** [Alert name or rule SID]
**Affected Assets:** [Hostname(s), IP(s), Agent ID(s)]

### Pre-Remediation State

- Total vulnerabilities/alerts: X
- Critical: X | High: X | Medium: X | Low: X

## Investigation

### Findings

What was discovered during investigation.

### Root Cause

The underlying cause of the incident.

### ATT&CK Mapping

| Tactic | Technique | Evidence |
|--------|-----------|----------|
| [Tactic] | [Technique ID + Name] | [What was observed] |

## Remediation

### Actions Taken

1. Step-by-step remediation actions

### Post-Remediation State

- Total vulnerabilities/alerts: X
- Critical: X | High: X | Medium: X | Low: X
- **Reduction:** X eliminated (Y%)

## Evidence

| File | Description |
|------|-------------|
| `evidence/pre-*.csv` | Pre-remediation vulnerability export |
| `evidence/post-*.csv` | Post-remediation vulnerability export |
| `evidence/*.jpg` | Dashboard screenshots |

## Lessons Learned

What would be done differently next time. Process improvements.

## References

- Related playbooks
- External advisories
- Tool documentation
