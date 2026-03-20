# SOC Playbook Template

**Title:** [Brief, descriptive name]  
**Type:** [Category - e.g., Malware Response, Vulnerability Remediation, Phishing Investigation]  
**Tooling:** [Primary tools used]  
**Difficulty:** [Beginner / Intermediate / Advanced]  
**Estimated Time:** [How long this typically takes]  
**Last Updated:** YYYY-MM-DD  

---

## 🎯 Learning Objectives

After completing this playbook, you should understand:
1. [Concept 1 - e.g., "How CVE scanners identify vulnerable packages"]
2. [Concept 2 - e.g., "The difference between patch and full version upgrades"]
3. [Concept 3 - e.g., "Why version standardization reduces attack surface"]

**Prerequisites:** [What knowledge is assumed before starting]

---

## 📋 Overview

[2-3 sentences explaining what this playbook addresses and why it matters]

**Real-World Example:** [Brief case study from actual incident - makes it concrete]

---

## 🚨 Detection

### Alert Signature
- **Rule ID/Group:** [Wazuh rule details]
- **Severity:** [Critical/High/Medium/Low]
- **Key Fields:** [What data points matter most]

### Initial Triage Questions
1. [Question to scope impact]
2. [Question to identify affected assets]
3. [Question to determine urgency]

### Dashboard Query
```sql
-- Query to find affected assets
SELECT agent_name, [fields]
FROM alerts 
WHERE [conditions];
```

---

## 🔍 Investigation

### Why This Step Matters
[Educational context: what are we looking for and why?]

### Step 1: [Action Name]
```powershell/bash
# Command with comments explaining what it does
```

**Expected Output:** [What you should see if things are normal/abnormal]

### Step 2: [Action Name]
```powershell/bash
# Command
```

**Key Insight:** [What this tells us about the situation]

---

## 🛠️ Remediation

### Option A: [Approach Name] (Recommended for [scenario])
[When to use this approach]

```powershell/bash
# Commands
```

**Trade-offs:** [Pros/cons of this approach]

### Option B: [Alternative Approach] (Use when [condition])
[When this makes more sense]

```powershell/bash
# Commands
```

---

## ✅ Verification

### Immediate Check
```powershell/bash
# Quick validation command
```

### Wazuh Confirmation
```sql
-- Query to verify CVE is cleared
SELECT [fields]
FROM alerts 
WHERE [conditions];
```

**Success Criteria:** [What "done" looks like]

---

## 📝 Post-Remediation

### Documentation Checklist
- [ ] [Item 1]
- [ ] [Item 2]
- [ ] [Item 3]

### Prevention
- [ ] [How to stop this from happening again]
- [ ] [Process/policy change needed]

---

## 🧠 Lessons Learned

| Issue | Root Cause | Prevention |
|-------|-----------|------------|
| [What went wrong] | [Why it happened] | [How to avoid] |

---

## 📚 References

- **Case Study:** [Link to actual incident notes]
- **External Docs:** [Vendor CVE, Microsoft docs, etc.]
- **Related Playbooks:** [Links to similar procedures]

---

## 📊 Playbook Metrics

| Date | Action | Analyst | Time Spent | Notes |
|------|--------|---------|------------|-------|
| YYYY-MM-DD | [What happened] | [Who] | [Hours] | [Context] |

---

*Template version 1.0 | Created for Polk State College SOC*
