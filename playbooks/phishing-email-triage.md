# Phishing Email Triage

**Title:** Phishing Email Investigation and Response
**Type:** Phishing Investigation
**Tooling:** TheHive, Cortex, MISP, Wazuh, MITRE ATT&CK
**Difficulty:** Intermediate
**Estimated Time:** 30-60 minutes
**Last Updated:** 2026-02-09

---

## Learning Objectives

After completing this playbook, you should understand:
1. How to extract and analyze email headers for delivery path and authentication results
2. How to check embedded IOCs (URLs, domains, IPs, attachments) against threat intelligence
3. How to create and manage a TheHive case for tracking phishing incidents

**Prerequisites:** Basic understanding of email protocols (SMTP, SPF, DKIM, DMARC). Access to TheHive, Cortex, and MISP instances.

---

## Overview

A user reports a suspicious email. The analyst must determine whether the email is malicious, extract indicators, enrich them against threat intelligence, and take appropriate action. This playbook covers the full lifecycle from report to resolution.

**Real-World Example:** A finance department employee receives an email impersonating the CEO requesting an urgent wire transfer. The email passes SPF but fails DKIM, contains a link to a credential harvesting page hosted on a recently registered domain.

---

## Detection

### Alert Signature
- **Rule ID/Group:** Wazuh rule 3601-3604 (email-related), custom rule for user-reported phishing
- **Severity:** Medium (escalate to High if credentials were entered)
- **Key Fields:** From address, Reply-To, Subject, embedded URLs, attachment hashes

### Initial Triage Questions
1. Did the recipient click any links or open any attachments?
2. Did the recipient enter credentials on any linked page?
3. How many users received the same email (check by subject or sender)?

### Dashboard Query
```sql
-- Find all emails from the reported sender in Wazuh logs
SELECT agent_name, data.srcip, data.subject, data.from, data.to, timestamp
FROM alerts
WHERE rule.groups = 'email'
  AND data.from LIKE '%suspicious-sender@%'
ORDER BY timestamp DESC;
```

---

## Investigation

### Why This Step Matters
Email-based attacks remain the most common initial access vector (MITRE T1566). Thorough header analysis reveals spoofing attempts, delivery infrastructure, and authentication failures that distinguish phishing from legitimate mail.

### Step 1: Collect the Original Email

Obtain the raw email with full headers. Do not rely on forwarded copies, which strip critical header information.

```bash
# If available via mail server API (Exchange/M365)
# Export as .eml file preserving all headers

# Key headers to extract:
# - Received: (full delivery chain, read bottom-to-top)
# - From: / Reply-To: (mismatch indicates spoofing)
# - Return-Path: (envelope sender)
# - Authentication-Results: (SPF, DKIM, DMARC verdicts)
# - X-Originating-IP: (sender's actual IP)
# - Message-ID: (useful for log correlation)
```

**Expected Output:** A complete .eml file or full header dump showing the delivery path and authentication results.

### Step 2: Analyze Authentication Results

```
# Check SPF, DKIM, and DMARC results in Authentication-Results header
#
# SPF pass + DKIM fail = possible domain spoofing with authorized IP
# SPF fail + DKIM fail = likely spoofed sender
# DMARC fail = domain owner policy says reject/quarantine
#
# Example header:
# Authentication-Results: mx.google.com;
#   spf=fail (sender IP not in SPF record) smtp.mailfrom=ceo@company.com;
#   dkim=fail (signature verification failed);
#   dmarc=fail (policy=reject)
```

**Key Insight:** A DMARC fail with policy=reject that still reached the inbox indicates a misconfigured mail gateway. Flag this for the email admin team.

### Step 3: Extract Indicators of Compromise

```bash
# From the email body and headers, extract:
# - Sender IP (X-Originating-IP or first Received header)
# - Sender domain (From: header)
# - Reply-To domain (if different from From:)
# - All URLs in the body (defang before sharing: hxxps://)
# - Attachment filenames and hashes (MD5, SHA256)
# - Any embedded images with external src URLs
```

### Step 4: Check IOCs Against MISP

```
# Via misp-mcp:
misp-mcp.search_attributes({value: "evil-domain.com", type: "domain"})
misp-mcp.search_attributes({value: "185.220.101.34", type: "ip-src"})
misp-mcp.search_attributes({value: "a1b2c3d4...", type: "sha256"})

# Check warninglists for false positives:
misp-mcp.get_warninglists({value: "185.220.101.34"})
```

**Expected Output:** MISP returns matching events with context: associated campaigns, threat actors, TLP markings, and related indicators.

### Step 5: Enrich with Cortex Analyzers

```
# Via cortex-mcp, run analyzers on extracted IOCs:
cortex-mcp.run_analyzer("VirusTotal_GetReport_3_1", {data: "evil-domain.com", dataType: "domain"})
cortex-mcp.run_analyzer("Urlscan_io_Scan_0_1_0", {data: "https://evil-domain.com/login", dataType: "url"})
cortex-mcp.run_analyzer("AbuseIPDB_1_0", {data: "185.220.101.34", dataType: "ip"})
cortex-mcp.run_analyzer("Whois_1_0", {data: "evil-domain.com", dataType: "domain"})

# For attachments:
cortex-mcp.run_analyzer("VirusTotal_GetReport_3_1", {data: "sha256hash", dataType: "hash"})
cortex-mcp.run_analyzer("HybridAnalysis_GetReport_1_0", {data: "sha256hash", dataType: "hash"})
```

### Step 6: Determine Scope of Exposure

```sql
-- Check Wazuh for other recipients (mail gateway logs)
SELECT data.to, data.subject, data.from, timestamp
FROM alerts
WHERE data.subject LIKE '%urgent wire transfer%'
   OR data.from LIKE '%suspicious-sender@%'
ORDER BY timestamp DESC;

-- Check Zeek DNS logs for anyone who resolved the phishing domain
-- Via zeek-mcp:
zeek-mcp.query_dns({query: "evil-domain.com"})

-- Check Zeek HTTP logs for anyone who visited the URL
zeek-mcp.query_http({host: "evil-domain.com"})
```

---

## Remediation

### Option A: No Interaction (User Did Not Click)

The email was reported without interaction. Block and document.

```
# 1. Add sender domain and IP to email gateway blocklist
# 2. Add IOCs to MISP for future detection
misp-mcp.create_event({
  info: "Phishing: CEO impersonation targeting finance dept",
  threat_level: 2,
  distribution: 0
})
misp-mcp.add_attribute({event_id: "new", type: "domain", value: "evil-domain.com"})
misp-mcp.add_attribute({event_id: "new", type: "ip-src", value: "185.220.101.34"})

# 3. Delete email from all mailboxes (Exchange/M365 compliance search)
```

**Trade-offs:** Quick resolution, minimal disruption. Risk: other users may have received and interacted without reporting.

### Option B: User Clicked Link or Entered Credentials (Compromised)

Credentials may be compromised. Escalate immediately.

```
# 1. Force password reset for affected user(s)
# 2. Revoke active sessions (Azure AD / on-prem AD)
# 3. Enable MFA if not already active
# 4. Check for mailbox rules (attackers often add forwarding rules)
# 5. Review recent login activity for the compromised account
# 6. Check Wazuh for suspicious activity from the user's endpoint

wazuh-mcp.get_alerts({agent_name: "DESKTOP-USER01", level: ">8", timeframe: "24h"})

# 7. If malware was downloaded, isolate the endpoint
sophos-mcp.isolate_endpoint({hostname: "DESKTOP-USER01"})
```

---

## Verification

### Immediate Check
```
# Verify phishing domain is blocked
nslookup evil-domain.com  # Should return NXDOMAIN or sinkhole IP

# Verify email purged from mailboxes
# Check Exchange compliance search results

# Verify password was reset (if applicable)
# Check AD last password change timestamp
```

### Wazuh Confirmation
```sql
-- Confirm no further emails from the sender
SELECT count(*) FROM alerts
WHERE data.from LIKE '%suspicious-sender@%'
  AND timestamp > 'post-remediation-time';
```

**Success Criteria:** Phishing domain blocked, emails purged, IOCs added to MISP, affected credentials reset, no further delivery from sender.

---

## Post-Remediation

### Documentation Checklist
- [ ] TheHive case created with all observables and timeline
- [ ] IOCs added to MISP with appropriate TLP marking
- [ ] Email gateway blocklist updated
- [ ] User notified of outcome and educated on phishing indicators
- [ ] If credentials compromised: password reset confirmed, MFA verified

### Prevention
- [ ] Review DMARC policy for the impersonated domain (publish reject policy)
- [ ] Consider phishing simulation training for targeted department
- [ ] Evaluate email gateway filtering rules for similar patterns

---

## MCP Integration

An AI assistant with access to the MCP servers can automate most of this playbook:

1. **Automated IOC extraction:** Parse email headers and body to extract all indicators
2. **Parallel enrichment:** Query MISP, run Cortex analyzers, and check Zeek logs simultaneously
3. **Scope assessment:** Search Wazuh and Zeek for all users who received or interacted with the email
4. **Case creation:** Build a TheHive case with all observables, enrichment results, and timeline entries pre-populated
5. **ATT&CK mapping:** Automatically tag the case with T1566.001 (Spearphishing Attachment) or T1566.002 (Spearphishing Link)

**Example AI prompt:**
```
"A user in finance reported a suspicious email from ceo@company-misspelled.com with a link
to https://company-misspelled.com/invoice. Investigate this phishing attempt: check all
IOCs against MISP and VirusTotal, see if anyone else received it, and create a TheHive case."
```

---

## Indicators to Watch

| Indicator Type | What to Look For |
|---------------|-----------------|
| Domain age | Registered within last 30 days |
| SPF/DKIM/DMARC | Any authentication failures |
| URL patterns | Login pages, credential harvesting forms |
| Reply-To mismatch | Different from the From: address |
| Attachment type | .html, .htm, .iso, .img, .vhd, .one, .lnk |
| Language/urgency | "Urgent," "immediate action required," financial requests |
| Sender history | First-time sender to this recipient |

---

## Lessons Learned

| Issue | Root Cause | Prevention |
|-------|-----------|------------|
| Phishing email bypassed gateway | New domain not yet in blocklists | Implement domain age filtering (block domains < 30 days) |
| Multiple users clicked before report | No automated phishing detection | Deploy URL rewriting with time-of-click analysis |
| Credentials harvested before password reset | Delay between report and response | Automate credential reset workflow for confirmed phishing |

---

## References

- **MITRE ATT&CK:** [T1566 - Phishing](https://attack.mitre.org/techniques/T1566/)
- **NIST SP 800-61:** Computer Security Incident Handling Guide
- **Related Playbooks:** lateral-movement-detection.md (if phishing leads to compromise)

---

## Playbook Metrics

| Date | Action | Analyst | Time Spent | Notes |
|------|--------|---------|------------|-------|
| | | | | |
