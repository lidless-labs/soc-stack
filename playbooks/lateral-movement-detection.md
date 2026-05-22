# Lateral Movement Detection and Response

**Title:** Lateral Movement Detection via Wazuh and Zeek Correlation
**Type:** Intrusion Response
**Tooling:** Wazuh, Zeek, Suricata, TheHive, Cortex, MISP, MITRE ATT&CK, Sophos
**Difficulty:** Advanced
**Estimated Time:** 1-3 hours
**Last Updated:** 2026-02-09

---

## Learning Objectives

After completing this playbook, you should understand:
1. How to identify lateral movement through correlated network and endpoint telemetry
2. How to trace an attacker's path across multiple systems using Zeek connection logs and Wazuh alerts
3. How to contain an active intrusion while preserving forensic evidence

**Prerequisites:** Understanding of Windows authentication (NTLM, Kerberos), SMB protocol, RDP, WMI, and PsExec. Familiarity with Wazuh rule groups and Zeek log structure.

---

## Overview

An attacker who has compromised an initial endpoint will attempt to move laterally to access additional systems, escalate privileges, and reach high-value targets (domain controllers, file servers, databases). This playbook covers detection of lateral movement through Wazuh alerts, Zeek network correlation, and coordinated containment.

**Real-World Example:** A compromised workstation in accounting begins making SMB connections to the file server and domain controller using a service account. Wazuh detects anomalous logon events. Zeek shows the workstation initiating connections to internal hosts it has never contacted before. Suricata fires ET POLICY signatures for PsExec-like behavior.

---

## Detection

### Alert Signature
- **Wazuh Rule IDs:**
  - 60106: Logon with explicit credentials (Type 9)
  - 60122: Remote logon via network (Type 3) from unusual source
  - 60132: Pass-the-hash detected (NTLM logon with no prior Kerberos)
  - 92650-92660: Custom rules for lateral movement patterns
  - 87101-87105: Web attack / exploitation attempt
- **Suricata Signatures:**
  - ET POLICY SMB2 NT Create AndX Request For an Executable
  - ET ATTACK_RESPONSE PsExec Service Created
  - ET POLICY Possible Lateral Movement via WMI
- **Severity:** High to Critical
- **Key Fields:** Source IP, destination IP, logon type, authentication package, target username

### Initial Triage Questions
1. Is the source system a workstation or server? (Workstations initiating server-to-server connections are suspicious.)
2. Is the account used for lateral movement a privileged account (domain admin, service account)?
3. How many destination systems has the source contacted in the last hour?

### Dashboard Query
```sql
-- Wazuh: Find Type 3 (network) logons from non-server sources
SELECT agent_name, data.srcip, data.dstuser, data.logon_type,
       rule.id, rule.description, timestamp
FROM alerts
WHERE rule.groups LIKE '%authentication%'
  AND data.logon_type = '3'
  AND data.srcip NOT IN ('198.51.100.1', '198.51.100.2')  -- Exclude known DCs
  AND rule.level >= 8
ORDER BY timestamp DESC
LIMIT 100;
```

---

## Investigation

### Why This Step Matters
Lateral movement is a mid-stage tactic (MITRE TA0008). By the time you detect it, the attacker has already achieved initial access and likely has valid credentials. Speed matters: every minute of delay allows the attacker to reach additional systems.

### Step 1: Identify the Source (Patient Zero)

```
# Via wazuh-mcp: Get all alerts from the suspected source
wazuh-mcp.get_alerts({
  src_ip: "198.51.100.50",
  level: ">6",
  timeframe: "48h"
})

# Look for the earliest alert. The first compromise indicator
# tells you when the attacker gained access.
# Common initial access alerts:
#   - Malware detection (rule 554)
#   - Exploitation attempt (rule 87101)
#   - Anomalous PowerShell execution (rule 91801)
```

**Expected Output:** A timeline of alerts showing progression from initial compromise to lateral movement.

### Step 2: Map the Attacker's Network Path

```
# Via zeek-mcp: Get ALL connections from the source host
zeek-mcp.investigate_host("198.51.100.50")

# Focus on internal connections (filter out internet traffic)
zeek-mcp.query_connections({
  src_ip: "198.51.100.50",
  dst_subnet: "198.51.100.0/8",
  timeframe: "48h"
})

# Key ports indicating lateral movement:
#   445 (SMB) - File shares, PsExec, WMI
#   135 (RPC) - DCOM, WMI
#   3389 (RDP) - Remote Desktop
#   5985/5986 (WinRM) - PowerShell Remoting
#   22 (SSH) - Linux lateral movement
```

**Key Insight:** Build a connection graph. If workstation A (198.51.100.50) connects to server B (198.51.100.20) on port 445, and then server B connects to domain controller C (198.51.100.1) on port 445, you have a two-hop lateral movement chain.

### Step 3: Check Suricata for Signature Matches

```
# Via suricata-mcp: Look for lateral movement signatures
suricata-mcp.get_alerts({
  src_ip: "198.51.100.50",
  timeframe: "48h"
})

# Also check the intermediate hosts
suricata-mcp.get_alerts({
  src_ip: "198.51.100.20",
  timeframe: "48h"
})

# Key signatures:
#   ET POLICY SMB2 NT Create AndX Request For an Executable
#   ET ATTACK_RESPONSE PsExec Service Created
#   ET POLICY Possible WMI Remote Process Creation
```

### Step 4: Identify Compromised Accounts

```
# Via wazuh-mcp: Find all accounts used from the source
wazuh-mcp.get_alerts({
  src_ip: "198.51.100.50",
  rule_group: "authentication_success",
  timeframe: "48h"
})

# Look for:
#   - Service accounts used interactively
#   - Domain admin accounts from workstations
#   - Accounts authenticating via NTLM instead of Kerberos
#   - New accounts created during the attack window
```

### Step 5: Check for Data Staging and Exfiltration

```
# Via zeek-mcp: Look for large data transfers from compromised hosts
zeek-mcp.query_connections({
  src_ip: "198.51.100.50",
  min_bytes: 10000000,  # >10 MB transfers
  timeframe: "48h"
})

# Check for external connections (exfiltration)
zeek-mcp.query_connections({
  src_ip: "198.51.100.50",
  dst_subnet: "!198.51.100.0/8",  # Non-internal
  timeframe: "48h"
})

# Check DNS for data exfiltration via DNS tunneling
zeek-mcp.query_dns({
  src_ip: "198.51.100.50",
  min_query_length: 50  # Long DNS queries suggest tunneling
})
```

### Step 6: Enrich External IOCs

```
# Any external IPs or domains identified in the investigation
cortex-mcp.run_analyzer("VirusTotal_GetReport_3_1", {data: "203.0.113.50", dataType: "ip"})
cortex-mcp.run_analyzer("AbuseIPDB_1_0", {data: "203.0.113.50", dataType: "ip"})
misp-mcp.search_attributes({value: "203.0.113.50"})

# Map to ATT&CK
mitre-mcp.map_techniques([
  "SMB lateral movement",
  "PsExec service creation",
  "Pass-the-hash authentication",
  "Credential dumping"
])
# Expected: T1021.002, T1569.002, T1550.002, T1003
```

---

## Remediation

### Option A: Targeted Containment (Recommended for Active Intrusion)

Isolate compromised systems while preserving evidence. Do not shut down or reboot, as this destroys volatile memory artifacts.

```
# 1. Isolate Patient Zero and all confirmed compromised hosts
# Via sophos-mcp (if Sophos-managed):
sophos-mcp.isolate_endpoint({hostname: "ACCT-WS-01"})
sophos-mcp.isolate_endpoint({hostname: "FILE-SVR-01"})

# If not Sophos-managed, use network-level isolation:
# - Move to quarantine VLAN
# - Block at firewall (both directions)
# - Disable switch port (last resort)

# 2. Disable compromised accounts in Active Directory
# Disable the accounts, do NOT delete them (preserve audit trail)
# Reset passwords for all accounts used during the attack

# 3. Block attacker C2 infrastructure
# Add external IPs/domains to firewall blocklist
# Add to MISP for organizational awareness
misp-mcp.add_attribute({event_id: "incident-event", type: "ip-dst", value: "203.0.113.50"})
```

**Trade-offs:** Preserves forensic evidence, minimizes business disruption. Risk: attacker may have additional persistence mechanisms on hosts you haven't identified.

### Option B: Full Network Segment Isolation (Use When Scope is Unclear)

When you cannot confidently identify all compromised systems, isolate the entire network segment.

```
# 1. Isolate the affected VLAN at the firewall
#    Allow only management traffic (your investigation access)

# 2. Monitor the segment boundary for continued C2 traffic
#    This reveals any compromised hosts you missed

# 3. Systematically investigate each host in the segment
#    Use Wazuh agent data to check for persistence mechanisms

wazuh-mcp.get_alerts({
  agent_group: "accounting-vlan",
  rule_group: "syscheck",  # File integrity changes
  timeframe: "7d"
})
```

---

## Verification

### Immediate Check
```
# Verify isolated endpoints cannot reach other systems
# From an isolated host, attempt to ping the gateway:
ping 198.51.100.1  # Should timeout

# Verify compromised accounts are disabled
# Check AD account status

# Verify C2 domains/IPs are blocked
# From the firewall, confirm block rules are active
```

### Wazuh Confirmation
```sql
-- Confirm no new lateral movement alerts from contained hosts
SELECT agent_name, rule.description, data.srcip, data.dstip, timestamp
FROM alerts
WHERE data.srcip IN ('198.51.100.50', '198.51.100.20')
  AND rule.groups LIKE '%authentication%'
  AND timestamp > 'containment-time'
ORDER BY timestamp DESC;
```

**Success Criteria:** No new authentication events from compromised hosts. No C2 traffic in Zeek/Suricata logs. All compromised accounts disabled.

---

## Post-Remediation

### Documentation Checklist
- [ ] TheHive case created with full timeline of attacker actions
- [ ] All compromised hosts identified and listed
- [ ] All compromised accounts identified and reset
- [ ] IOCs added to MISP (C2 IPs, domains, malware hashes, tools used)
- [ ] Forensic images captured from compromised systems (if needed)
- [ ] ATT&CK techniques documented in the case

### Prevention
- [ ] Implement network segmentation to limit lateral movement paths
- [ ] Deploy Local Administrator Password Solution (LAPS) to prevent credential reuse
- [ ] Restrict privileged account logon to authorized systems only (Tier model)
- [ ] Enable Windows Credential Guard to prevent credential dumping
- [ ] Increase Wazuh rule sensitivity for authentication anomalies

---

## MCP Integration

An AI assistant can significantly accelerate lateral movement investigation:

1. **Rapid scoping:** Query Zeek connection logs for the source host across all protocols simultaneously, building a connection graph in seconds
2. **Cross-tool correlation:** Match Wazuh authentication alerts with Zeek connection logs and Suricata signatures to confirm lateral movement hops
3. **Account audit:** Extract all accounts used from the compromised host and check each against normal baseline behavior
4. **Automated containment:** Isolate endpoints via Sophos MCP while simultaneously creating the TheHive case
5. **ATT&CK mapping:** Map the full attack chain to ATT&CK techniques and identify detection gaps

**Example AI prompt:**
```
"We have a suspected lateral movement incident originating from 198.51.100.50. Map all internal
connections from this host in the last 48 hours. For each destination host, check Wazuh for
authentication events and Suricata for lateral movement signatures. Build a timeline showing
the attacker's path and create a TheHive case with all findings."
```

---

## Indicators to Watch

| Indicator Type | What to Look For |
|---------------|-----------------|
| Authentication anomalies | Type 3 logons from workstations to servers at unusual hours |
| Protocol misuse | SMB to many hosts in short time (scanning behavior) |
| Account abuse | Service accounts used interactively, admin accounts from workstations |
| Tool signatures | PsExec, WMI remote execution, PowerShell remoting |
| Network patterns | New internal connections that have no historical baseline |
| Data movement | Large SMB transfers, RAR/ZIP creation on servers, DNS tunneling |

---

## Lessons Learned

| Issue | Root Cause | Prevention |
|-------|-----------|------------|
| Attacker moved from workstation to DC in minutes | Flat network, no segmentation | Implement VLAN segmentation with firewall between tiers |
| Domain admin credentials reused across systems | No tiered admin model | Deploy tier 0/1/2 admin model with separate accounts |
| Lateral movement not detected for 6 hours | Insufficient Wazuh rule tuning | Add custom rules for workstation-to-server auth patterns |

---

## References

- **MITRE ATT&CK:** [TA0008 - Lateral Movement](https://attack.mitre.org/tactics/TA0008/)
- **MITRE Techniques:** T1021 (Remote Services), T1550 (Use Alternate Auth Material), T1570 (Lateral Tool Transfer)
- **Related Playbooks:** phishing-email-triage.md (common precursor), ransomware-initial-response.md (common follow-on)

---

## Playbook Metrics

| Date | Action | Analyst | Time Spent | Notes |
|------|--------|---------|------------|-------|
| | | | | |
