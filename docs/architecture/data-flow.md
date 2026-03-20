# Data Flow

This document describes how data moves through the SOC stack, from initial network capture through detection, enrichment, and incident response. Each stage is covered with the tools involved and how the MCP layer enables AI-driven investigation.

---

## High-Level Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DATA SOURCES                                  │
│                                                                      │
│   Network Tap/SPAN ──────┐     Endpoint Agents ──────┐              │
│   Cloud Logs ────────────┤     Syslog Sources ───────┤              │
│   Email Gateway ─────────┘     AD/LDAP Events ───────┘              │
└──────────────┬──────────────────────────┬───────────────────────────┘
               │                          │
       ┌───────┴───────┐          ┌───────┴───────┐
       │  NETWORK LAYER │          │ ENDPOINT LAYER │
       │                │          │                │
       │  ┌──────────┐  │          │  ┌──────────┐  │
       │  │   Zeek   │  │          │  │  Wazuh   │  │
       │  │  (NSM)   │  │          │  │  Agent   │  │
       │  └────┬─────┘  │          │  └────┬─────┘  │
       │       │        │          │       │        │
       │  ┌────┴─────┐  │          │       │        │
       │  │ Suricata │  │          │       │        │
       │  │(IDS/IPS) │  │          │       │        │
       │  └────┬─────┘  │          │       │        │
       └───────┼────────┘          └───────┼────────┘
               │                           │
               └───────────┬───────────────┘
                           │
                    ┌──────┴──────┐
                    │    Wazuh    │
                    │   Manager   │
                    │   (SIEM)    │
                    │             │
                    │ - Decode    │
                    │ - Correlate │
                    │ - Alert     │
                    │ - Archive   │
                    └──────┬──────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                │
   ┌──────┴──────┐  ┌─────┴─────┐  ┌──────┴──────┐
   │   Cortex    │  │   MISP    │  │  TheHive    │
   │  (Analyze)  │  │  (Intel)  │  │  (Cases)    │
   │             │  │           │  │             │
   │ VT, Shodan  │  │ IOC feeds │  │ Cases       │
   │ AbuseIPDB   │  │ Sightings │  │ Tasks       │
   │ Whois       │  │ Sharing   │  │ Observables │
   └─────────────┘  └───────────┘  └─────────────┘
```

---

## Stage 1: Network Traffic Capture

Raw network traffic enters the pipeline through a network tap or SPAN port on the core switch. Both Zeek and Suricata process the same traffic in parallel, each providing a different perspective.

```
        Network Tap / SPAN Port
        (mirror of all traffic)
               │
     ┌─────────┴─────────┐
     │                    │
     ▼                    ▼
┌─────────┐        ┌──────────┐
│  Zeek   │        │ Suricata │
│         │        │          │
│ WHAT:   │        │ WHAT:    │
│ Protocol│        │ Signature│
│ metadata│        │ matching │
│ logging │        │ + alerts │
│         │        │          │
│ OUTPUT: │        │ OUTPUT:  │
│ conn.log│        │ eve.json │
│ dns.log │        │ (alerts) │
│ http.log│        │ (flow)   │
│ ssl.log │        │ (dns)    │
│ files.log        │ (http)   │
│ smtp.log│        │ (tls)    │
│ ssh.log │        │ (file)   │
└────┬────┘        └────┬─────┘
     │                  │
     │   Both feed      │
     │   into Wazuh     │
     └───────┬──────────┘
             ▼
```

**Why both?** Zeek provides deep protocol analysis and metadata extraction. It tells you what happened at the application layer: every DNS query, every HTTP request, every file transferred. Suricata provides signature-based detection using rulesets (ET Open, ET Pro). It catches known-bad patterns: malware callbacks, exploit attempts, policy violations. Together they give you both visibility and detection.

---

## Stage 2: SIEM Correlation (Wazuh)

Wazuh Manager receives data from three sources:

1. **Zeek logs** via syslog or file monitoring
2. **Suricata alerts** via EVE JSON file monitoring
3. **Endpoint agents** reporting directly (Windows Event Logs, syscheck, rootcheck, syscollector)

```
Zeek logs ──────┐
                │
Suricata EVE ───┼──> Wazuh Manager
                │      │
Endpoint agents ┘      ├── Decode (extract fields from raw logs)
                       ├── Rule matching (15,000+ built-in rules)
                       ├── Correlation (cross-source pattern matching)
                       ├── Enrichment (GeoIP, CVE lookup, CDB lists)
                       └── Alert generation (severity 1-15)
                              │
                              ▼
                       Wazuh Indexer
                       (Elasticsearch/OpenSearch)
                              │
                              ├── Alerts index
                              ├── Archives index
                              └── Vulnerability index
```

**Key correlation examples:**

- Suricata fires ET MALWARE alert for IP X + Zeek shows DNS queries to DGA domains from same host = high-confidence compromise
- Wazuh agent detects new service installed + Suricata shows lateral movement signatures = active intrusion
- File integrity change on web server + HTTP logs show POST to /upload = potential webshell

---

## Stage 3: Enrichment and Analysis

Once Wazuh generates an alert, multiple enrichment paths activate:

### 3a. Threat Intelligence (MISP)

```
Wazuh Alert
  │
  ├── Extract observables (IPs, domains, hashes, URLs)
  │
  └──> MISP API
         │
         ├── Search attributes: Does this IOC appear in any events?
         ├── Check warninglists: Is this a known CDN/cloud IP (false positive)?
         ├── Get correlations: What other IOCs appear in the same events?
         ├── Retrieve context: Which threat actor? Which campaign?
         └── Record sighting: Update "last seen" for the indicator
```

**Feed sources into MISP:**
- CIRCL OSINT feed (community threat intel)
- Abuse.ch URLhaus, MalwareBazaar, ThreatFox
- AlienVault OTX
- Custom internal feeds
- Manual analyst contributions

### 3b. Observable Analysis (Cortex)

```
Suspicious Observable (IP, domain, hash, URL)
  │
  └──> Cortex API
         │
         ├── VirusTotal_GetReport ──> Reputation score, AV detections
         ├── AbuseIPDB ──> Abuse reports, ISP info, confidence %
         ├── Shodan_Host ──> Open ports, services, known vulns
         ├── MaxMind_GeoIP ──> Country, city, ASN
         ├── Urlscan_io ──> Screenshot, DOM analysis, redirects
         ├── MISP_2_1 ──> Cross-reference with threat intel
         └── Whois ──> Registration date, registrar, contact
                │
                ▼
         Analysis Report
         (verdict + raw data from each analyzer)
```

### 3c. ATT&CK Mapping (MITRE)

```
Alert Details + Enrichment Results
  │
  └──> MITRE ATT&CK Lookup
         │
         ├── Map observed behavior to techniques
         │     PowerShell execution ──> T1059.001
         │     New scheduled task ──> T1053.005
         │     SMB lateral movement ──> T1021.002
         │
         ├── Identify tactic progression
         │     Initial Access ──> Execution ──> Persistence ──> Lateral Movement
         │
         ├── Retrieve mitigations
         │     T1059.001 ──> Constrained Language Mode, Script Block Logging
         │
         └── Identify threat group (if pattern matches)
               APT29, Lazarus Group, FIN7, etc.
```

---

## Stage 4: Incident Response (TheHive)

TheHive receives alerts and manages the full incident lifecycle:

```
Wazuh Alert ──────────────┐
Suricata Alert ───────────┤
Manual Report ────────────┤
Email Gateway Alert ──────┘
         │
         ▼
   TheHive Alert Inbox
         │
         ├── Auto-merge: Group related alerts into single case
         ├── Analyst review: Triage, classify, assign
         │
         ▼
   ┌─────────────────────────────────────────┐
   │              TheHive Case               │
   │                                         │
   │  Severity: HIGH        TLP: AMBER       │
   │  Status: InProgress    PAP: RED         │
   │                                         │
   │  Observables:                           │
   │    IP: 185.220.101.34 (TOR exit)       │
   │    Domain: evil-c2.example.com          │
   │    Hash: a1b2c3... (malware sample)     │
   │                                         │
   │  Tasks:                                 │
   │    [x] Initial triage                   │
   │    [x] Run Cortex analyzers             │
   │    [ ] Check MISP for related intel     │
   │    [ ] Contain affected endpoints       │
   │    [ ] Forensic image collection        │
   │    [ ] Write incident report            │
   │                                         │
   │  Timeline:                              │
   │    09:15 Alert received from Wazuh      │
   │    09:22 Promoted to case               │
   │    09:30 Cortex analysis complete        │
   │    09:45 MISP match: APT29 campaign     │
   │    10:00 Endpoint isolated via Sophos   │
   └─────────────────────────────────────────┘
```

---

## Stage 5: The MCP Layer (AI Investigation)

The MCP layer sits between the AI assistant and every tool in the stack. It translates natural language investigation into structured API calls across all tools simultaneously.

```
┌──────────────────────────────────────────────────────────────────┐
│                        AI ASSISTANT                               │
│                  (Claude, GPT, or any LLM)                        │
│                                                                   │
│  "Investigate the alert for 185.220.101.34. Check all sources,   │
│   determine if this is a real threat, and create a case if so."  │
└───────────────────────────┬──────────────────────────────────────┘
                            │ MCP Protocol (stdio or HTTP)
                            │
┌───────────────────────────┴──────────────────────────────────────┐
│                       MCP SERVER LAYER                            │
│                                                                   │
│  Step 1: DETECT                                                   │
│  ┌───────────┐  wazuh-mcp.get_alerts({src_ip: "185.220.101.34"})│
│  │ wazuh-mcp │  Result: 3 alerts, rule 87101 (web attack),       │
│  └───────────┘  severity 12, agent: web-server-01                │
│                                                                   │
│  Step 2: SCOPE                                                    │
│  ┌──────────┐   zeek-mcp.investigate_host("185.220.101.34")     │
│  │ zeek-mcp │   Result: 47 connections, DNS to 3 DGA domains,   │
│  └──────────┘   HTTP POST to /upload, 2.3 GB transferred         │
│                                                                   │
│  ┌──────────────┐ suricata-mcp.get_alerts({src: "185.220..."})  │
│  │ suricata-mcp │ Result: ET MALWARE CnC Beacon, ET POLICY      │
│  └──────────────┘ TOR Exit Node, 2 signature matches             │
│                                                                   │
│  Step 3: ENRICH                                                   │
│  ┌───────────┐  cortex-mcp.run_analyzer("VirusTotal", ip)       │
│  │cortex-mcp │  Result: 14/92 vendors flag as malicious          │
│  └───────────┘                                                    │
│  ┌──────────┐   misp-mcp.search_attributes({value: ip})         │
│  │ misp-mcp │   Result: Matches event #5521 "APT29 Feb 2026"    │
│  └──────────┘                                                     │
│                                                                   │
│  Step 4: CONTEXT                                                  │
│  ┌───────────┐  mitre-mcp.map_techniques([behaviors...])         │
│  │ mitre-mcp │  Result: T1071.001, T1041, T1190                  │
│  └───────────┘  Mapped to: APT29 technique overlap 78%           │
│                                                                   │
│  Step 5: COMMERCIAL ENRICHMENT                                    │
│  ┌────────────┐ rapid7-mcp.get_vulnerabilities({ip: ...})        │
│  │ rapid7-mcp │ Result: 3 critical CVEs on web-server-01         │
│  └────────────┘                                                   │
│  ┌────────────┐ sophos-mcp.get_endpoint({hostname: ...})         │
│  │ sophos-mcp │ Result: Endpoint healthy, no local detections    │
│  └────────────┘                                                   │
│                                                                   │
│  Step 6: RESPOND                                                  │
│  ┌────────────┐  thehive-mcp.create_case({title: "APT29...",     │
│  │thehive-mcp │    severity: 3, observables: [...], tasks: [...]})│
│  └────────────┘  Result: Case #127 created, assigned to IR team  │
│                                                                   │
│  ┌────────────┐  sophos-mcp.isolate_endpoint("web-server-01")    │
│  │ sophos-mcp │  Result: Endpoint isolated from network          │
│  └────────────┘                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### AI Investigation Flow (Sequential)

```
1. DETECT    wazuh-mcp ──────> "What alerts fired for this IP?"
                                    │
2. SCOPE     zeek-mcp ───────> "Full network activity for this host"
             suricata-mcp ───> "Any IDS signature matches?"
                                    │
3. ENRICH    cortex-mcp ─────> "Run VirusTotal, AbuseIPDB, Shodan"
             misp-mcp ───────> "Known threat intel matches?"
             rapid7-mcp ─────> "Any vuln scan data for this asset?"
                                    │
4. CONTEXT   mitre-mcp ──────> "Map findings to ATT&CK framework"
                                    │
5. CONTAIN   sophos-mcp ─────> "Isolate compromised endpoint"
                                    │
6. RESPOND   thehive-mcp ────> "Create case with all evidence"
                                    │
7. DOCUMENT  AI generates ───> Investigation report with
                               evidence chain and recommendations
```

---

## Endpoint Monitoring Pipeline

Separate from network traffic, Wazuh agents on endpoints generate their own data:

```
      Endpoint Agents (Windows, Linux, macOS)
              │
              │  Wazuh Agent Modules:
              │  - syscheck (file integrity)
              │  - rootcheck (rootkit detection)
              │  - syscollector (hardware/software inventory)
              │  - vulnerability-detector (CVE scanning)
              │  - osquery (SQL-based system queries)
              │  - log collector (Windows Events, syslog, app logs)
              │
              ▼
        ┌───────────┐
        │   Wazuh   │
        │  Manager  │
        └─────┬─────┘
              │
              ├── Vulnerability alerts ──> TheHive (auto-create cases)
              ├── File integrity events ──> Cortex (hash analysis)
              ├── IOC matches ──────────> MISP (correlation check)
              └── All alerts ───────────> MITRE ATT&CK (TTP mapping)
```

---

## Threat Intelligence Pipeline

MISP acts as the central threat intelligence platform, both consuming external feeds and distributing IOCs to detection tools:

```
      External Feeds                    Internal Sightings
      (OSINT, ISAC, commercial)         (from Wazuh/Zeek/Suricata)
              │                                │
              ▼                                ▼
        ┌─────────────────────────────────────────┐
        │                MISP                      │
        │                                         │
        │  Events ──> Attributes ──> Tags         │
        │     │           │           │            │
        │  Correlate   Sightings   Taxonomies      │
        │     │                    (TLP, ATT&CK)   │
        └─────┬───────────────────────────────────┘
              │
              ├──> Wazuh (IOC watchlists for real-time matching)
              ├──> Suricata (auto-generated rules from IP/domain IOCs)
              ├──> Cortex (feed analyzers with context)
              └──> TheHive (enrich case observables automatically)
```

---

## Port Reference

| Service | Port | Protocol | Direction |
|---------|------|----------|-----------|
| Wazuh Manager API | 55000 | HTTPS | MCP server to Wazuh |
| Wazuh Agent | 1514 | TCP | Agent to Manager |
| Wazuh Agent (enrollment) | 1515 | TCP | Agent to Manager |
| Wazuh Indexer | 9200 | HTTPS | Manager to Indexer |
| Wazuh Dashboard | 443 | HTTPS | Browser to Dashboard |
| TheHive | 9000 | HTTP | MCP server to TheHive |
| Cortex | 9001 | HTTP | MCP server to Cortex |
| MISP | 443 | HTTPS | MCP server to MISP |
| Rapid7 InsightVM | 3780 | HTTPS | MCP server to InsightVM |
| Sophos Central | 443 | HTTPS | MCP server to Sophos Cloud |
| Elasticsearch | 9200 | HTTPS | Internal (TheHive/Cortex) |
| Cassandra | 9042 | TCP | Internal (TheHive backend) |
| MinIO | 9002 | HTTP | Internal (file storage) |
