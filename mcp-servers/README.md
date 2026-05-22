# MCP Servers

Nine Model Context Protocol servers for AI-augmented security operations. Each server connects an AI assistant (Claude, GPT, or any MCP client) directly to a security tool via the standardized MCP protocol.

## Server Overview

### API-Based (REST Client)

| Server | Tool | Default Port | Auth Method |
|--------|------|-------------|-------------|
| `wazuh-mcp` | Wazuh Manager | 55000 | User/Password (JWT) |
| `thehive-mcp` | TheHive 5 | 9000 | API Key (Bearer) |
| `cortex-mcp` | Cortex 3 | 9001 | API Key (Bearer) |
| `misp-mcp` | MISP | 443 | API Key (Header) |
| `rapid7-mcp` | Rapid7 InsightVM | 3780 | API Key (Header) |
| `sophos-mcp` | Sophos Central | Cloud API | API Key + Secret |

### Log-Based (File Parser)

| Server | Tool | Input | Format |
|--------|------|-------|--------|
| `zeek-mcp` | Zeek | Log directory | JSON or TSV |
| `suricata-mcp` | Suricata | EVE JSON log | Newline-delimited JSON |

### Data-Based (Offline Knowledge Base)

| Server | Tool | Source | Format |
|--------|------|--------|--------|
| `mitre-mcp` | MITRE ATT&CK | STIX 2.1 bundles | JSON (auto-downloaded) |

---

## Detailed Server Documentation

### 1. wazuh-mcp

**Repository:** [github.com/solomonneas/wazuh-mcp](https://github.com/solomonneas/wazuh-mcp)

**Connects to:** Wazuh Manager REST API (port 55000). Provides SIEM alert queries, agent management, vulnerability scanning results, and file integrity monitoring data.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `get_alerts` | Query alerts with filters (level, rule ID, agent, time range) |
| `get_alert_details` | Retrieve full alert details by ID |
| `list_agents` | List all registered agents with status and OS info |
| `get_agent_details` | Get detailed info for a specific agent (IP, version, last keep-alive) |
| `get_vulnerabilities` | Query vulnerability scan results by agent, severity, or CVE |
| `get_sca_results` | Retrieve Security Configuration Assessment results |
| `get_fim_events` | Query File Integrity Monitoring events (file changes) |
| `get_rules` | Search and retrieve Wazuh detection rules |
| `get_decoders` | List or search log decoders |
| `restart_agent` | Restart a specific Wazuh agent |

**Example Queries:**

```
"Show me all critical alerts from the last 24 hours"
"Which agents have CVE-2024-3094 in their vulnerability scan?"
"List all Windows agents that haven't checked in for over an hour"
"What file integrity changes happened on the web server today?"
"Show SCA compliance failures for agent 005"
```

**Environment Variables:**
```bash
WAZUH_URL=https://wazuh-manager:55000
WAZUH_USER=wazuh-wui
WAZUH_PASSWORD=your-password
WAZUH_VERIFY_SSL=false  # Optional, for self-signed certs
```

---

### 2. thehive-mcp

**Repository:** [github.com/solomonneas/thehive-mcp](https://github.com/solomonneas/thehive-mcp)

**Connects to:** TheHive 5 REST API (port 9000). Manages incident response cases, tasks, alerts, and observables.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `list_cases` | Query cases with filters (status, severity, tags, assignee) |
| `get_case` | Get full case details including custom fields |
| `create_case` | Create a new case with title, description, severity, TLP |
| `update_case` | Update case fields (status, impact, summary) |
| `list_tasks` | List tasks for a case |
| `create_task` | Add a task to a case with assignment and due date |
| `list_observables` | List observables (IOCs) attached to a case |
| `create_observable` | Add an observable (IP, domain, hash, email, URL) to a case |
| `list_alerts` | Query ingested alerts (from Wazuh, Suricata, etc.) |
| `promote_alert` | Promote an alert to a full case for investigation |
| `merge_alert` | Merge an alert into an existing case |

**Example Queries:**

```
"Create a case for the phishing email reported by user jsmith, severity HIGH"
"Show all open cases assigned to the SOC team"
"Add the suspicious IP 185.220.101.34 as an observable to case #42"
"What alerts came in from Wazuh in the last 6 hours?"
"Close case #38 with a resolution summary"
```

**Environment Variables:**
```bash
THEHIVE_URL=http://thehive:9000
THEHIVE_API_KEY=your-api-key
```

---

### 3. cortex-mcp

**Repository:** [github.com/solomonneas/cortex-mcp](https://github.com/solomonneas/cortex-mcp)

**Connects to:** Cortex 3 REST API (port 9001). Runs automated analysis on observables using 100+ analyzers and triggers response actions via responders.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `list_analyzers` | List available analyzers and their supported data types |
| `run_analyzer` | Execute an analyzer on an observable (returns job ID) |
| `get_job` | Check job status and retrieve results |
| `get_job_report` | Get the full analysis report for a completed job |
| `list_responders` | List available responder actions |
| `run_responder` | Execute a responder action (block IP, disable account) |
| `list_jobs` | Query recent analysis jobs with filters |

**Supported Analyzers (examples):**

- VirusTotal_GetReport: File hash, URL, domain, IP reputation
- AbuseIPDB_1_0: IP abuse reports and confidence score
- Shodan_Host: Open ports, services, vulnerabilities for an IP
- MaxMind_GeoIP: Geolocation data
- MISP_2_1: Check against MISP threat intel
- Urlscan_io_Scan: Screenshot and analysis of suspicious URLs
- CyberChef: Data decoding and transformation

**Example Queries:**

```
"Run VirusTotal on the hash a1b2c3d4e5f6..."
"Analyze the domain evil-phishing.com with all available analyzers"
"Check what analysis jobs are running right now"
"Get the full report from job ID abc123"
"Run the Mailer responder to notify the IR team"
```

**Environment Variables:**
```bash
CORTEX_URL=http://cortex:9001
CORTEX_API_KEY=your-api-key
```

---

### 4. misp-mcp

**Repository:** [github.com/solomonneas/misp-mcp](https://github.com/solomonneas/misp-mcp)

**Connects to:** MISP REST API (port 443). Manages threat intelligence events, attributes (IOCs), correlations, and sharing.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `search_events` | Search events by keyword, date range, tag, or threat level |
| `get_event` | Get full event details with all attributes |
| `create_event` | Create a new threat intelligence event |
| `add_attribute` | Add an IOC (IP, domain, hash, email) to an event |
| `search_attributes` | Search across all events for a specific indicator value |
| `get_correlations` | Find events that share common indicators |
| `tag_event` | Apply taxonomy tags (TLP, ATT&CK technique, threat actor) |
| `get_warninglists` | Check if an indicator matches known false-positive lists |
| `export_iocs` | Export IOCs in STIX, CSV, or Suricata rule format |
| `get_statistics` | Dashboard statistics (event count, attribute breakdown) |

**Example Queries:**

```
"Search for any events containing the IP 45.155.205.233"
"Create a new event for the APT29 campaign we identified today"
"Add all file hashes from our malware analysis to event #1234"
"Export all IP indicators tagged TLP:GREEN as Suricata rules"
"Which events correlate with the domain c2-server.evil.com?"
```

**Environment Variables:**
```bash
MISP_URL=https://misp.local
MISP_API_KEY=your-api-key
MISP_VERIFY_SSL=false  # Optional
```

---

### 5. zeek-mcp

**Repository:** [github.com/solomonneas/zeek-mcp](https://github.com/solomonneas/zeek-mcp)

**Connects to:** Zeek log files on disk. Parses and queries structured network metadata logs for deep protocol analysis and host investigation.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `query_connections` | Search conn.log by IP, port, protocol, duration, bytes |
| `query_dns` | Search dns.log by query name, response, query type |
| `query_http` | Search http.log by host, URI, method, user agent, status |
| `query_ssl` | Search ssl.log by server name (SNI), issuer, JA3 hash |
| `query_files` | Search files.log by hash, MIME type, source, filename |
| `query_notices` | Search notice.log for Zeek-generated alerts |
| `investigate_host` | Aggregate all log types for a single IP (connections, DNS, HTTP, SSL) |
| `get_log_summary` | Summary statistics for a log directory (record counts, time range) |
| `query_smtp` | Search SMTP logs for email metadata |
| `query_ssh` | Search SSH connection logs |

**Example Queries:**

```
"Show all DNS queries from 198.51.100.50 in the last hour"
"What HTTP requests went to domains registered in the last 30 days?"
"Investigate all network activity for host 192.0.2.105"
"Find all SSL connections with an expired certificate"
"Which hosts downloaded executable files today?"
```

**Environment Variables:**
```bash
ZEEK_LOG_DIR=/opt/zeek/logs/current
ZEEK_LOG_FORMAT=json  # or tsv
```

---

### 6. suricata-mcp

**Repository:** [github.com/solomonneas/suricata-mcp](https://github.com/solomonneas/suricata-mcp)

**Connects to:** Suricata EVE JSON log file. Parses alerts, flow records, protocol events, and file transaction data from the unified event log.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `get_alerts` | Query IDS alerts by signature, severity, source/dest IP, time range |
| `get_alert_details` | Full alert details including payload and rule metadata |
| `query_flows` | Search flow records by IP, port, protocol, bytes transferred |
| `query_dns` | DNS query/response events from protocol parser |
| `query_http` | HTTP transaction events with headers and URIs |
| `query_tls` | TLS handshake events with JA3/JA4 fingerprints, SNI, certificate info |
| `query_fileinfo` | File transaction events with hashes and metadata |
| `get_stats` | Suricata engine statistics (packets, drops, decoder events) |
| `get_top_signatures` | Most frequently triggered alert signatures |
| `get_top_talkers` | Top source/destination IPs by alert count or traffic volume |

**Example Queries:**

```
"Show all HIGH severity alerts from the last 4 hours"
"What are the top 10 triggered signatures today?"
"Find any ET MALWARE alerts involving internal hosts"
"Show TLS connections with JA3 hash matching known Cobalt Strike"
"Which internal hosts have the most outbound flow volume?"
```

**Environment Variables:**
```bash
SURICATA_EVE_PATH=/var/log/suricata/eve.json
SURICATA_MAX_LINES=100000  # Optional, default 50000
```

---

### 7. mitre-mcp

**Repository:** [github.com/solomonneas/mitre-mcp](https://github.com/solomonneas/mitre-mcp)

**Connects to:** MITRE ATT&CK STIX 2.1 data bundles (downloaded and cached locally). Provides offline technique lookup, group attribution, detection mapping, and mitigation guidance.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `get_technique` | Look up a technique by ID (e.g., T1059.001) with full details |
| `search_techniques` | Search techniques by keyword, tactic, or platform |
| `get_group` | Get threat group profile with associated techniques |
| `search_groups` | Search groups by name, alias, or targeted sector |
| `get_software` | Look up malware or tool details with technique mappings |
| `get_mitigations` | Get mitigations for a specific technique |
| `get_detections` | Get data sources and detection methods for a technique |
| `get_tactic` | List all techniques under a tactic (e.g., Lateral Movement) |
| `map_techniques` | Map a list of observed behaviors to ATT&CK techniques |
| `get_coverage` | Analyze detection coverage against a technique set |

**Example Queries:**

```
"What is T1566.001 and how do we detect it?"
"Which techniques does APT29 commonly use?"
"List all Initial Access techniques for Windows"
"What mitigations apply to credential dumping (T1003)?"
"Map these findings to ATT&CK: PowerShell execution, scheduled task creation, lateral SMB movement"
```

**Environment Variables:**
```bash
MITRE_DATA_DIR=./data  # Optional, defaults to ./data
MITRE_AUTO_UPDATE=true  # Optional, auto-download latest STIX bundles
```

---

### 8. rapid7-mcp

**Repository:** [github.com/solomonneas/rapid7-mcp](https://github.com/solomonneas/rapid7-mcp)

**Connects to:** Rapid7 InsightVM (Nexpose) REST API (port 3780). Provides vulnerability management, asset discovery, and scan data for enterprise environments.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `list_assets` | Query assets by IP, hostname, OS, or risk score |
| `get_asset` | Get full asset details (software, services, vulnerabilities) |
| `get_vulnerabilities` | List vulnerabilities for an asset or across the environment |
| `get_vulnerability_details` | Full CVE details with CVSS, description, and remediation steps |
| `list_scans` | List recent and scheduled scans |
| `get_scan_results` | Retrieve results from a completed scan |
| `search_exploits` | Search for known exploits related to a vulnerability |
| `get_risk_scores` | Asset and site risk scoring for prioritization |
| `list_sites` | List configured scan sites and their asset membership |
| `get_remediation_report` | Get prioritized remediation steps for a site or asset group |

**Example Queries:**

```
"Show all critical vulnerabilities on the DMZ site"
"Which assets have the highest risk scores?"
"Get remediation steps for CVE-2024-21407 across all affected hosts"
"List assets running Apache 2.4.49 or older"
"What new vulnerabilities were found in yesterday's scan?"
```

**Environment Variables:**
```bash
RAPID7_URL=https://insightvm.local:3780
RAPID7_API_KEY=your-api-key
RAPID7_VERIFY_SSL=false  # Optional
```

---

### 9. sophos-mcp

**Repository:** [github.com/solomonneas/sophos-mcp](https://github.com/solomonneas/sophos-mcp)

**Connects to:** Sophos Central Cloud API. Manages endpoint protection, detection events, and response actions across the Sophos-managed fleet.

**Key Tools:**

| Tool | Description |
|------|-------------|
| `list_endpoints` | Query managed endpoints by health status, OS, group, or hostname |
| `get_endpoint` | Detailed endpoint info (health, tamper protection, last seen) |
| `list_alerts` | Query Sophos alerts by category, severity, and time range |
| `get_alert_details` | Full alert details with detection context and recommended actions |
| `isolate_endpoint` | Network-isolate a compromised endpoint (keeps Sophos connectivity) |
| `unisolate_endpoint` | Remove network isolation from an endpoint |
| `initiate_scan` | Trigger an on-demand scan on an endpoint |
| `list_policies` | List configured protection policies |
| `get_tamper_protection` | Check tamper protection status across endpoints |
| `list_exclusions` | List scan and detection exclusions |

**Example Queries:**

```
"Which endpoints have a bad health status?"
"Show all malware detection alerts from the last 48 hours"
"Isolate the workstation DESKTOP-ABC123 immediately"
"How many endpoints have tamper protection disabled?"
"List all endpoints that haven't communicated in over 7 days"
```

**Environment Variables:**
```bash
SOPHOS_CLIENT_ID=your-client-id
SOPHOS_CLIENT_SECRET=your-client-secret
SOPHOS_TENANT_ID=your-tenant-id  # Optional, for partner/MSP accounts
```

---

## Shared Configuration

All servers share:

- `tsconfig.base.json` for TypeScript compiler settings
- Consistent project structure (see architecture docs)
- Zod-validated environment variable configuration
- stdio transport by default (Streamable HTTP available)
- Unified error handling and logging patterns

## Quick Install (any server)

```bash
cd <server-name>
npm install
npm run build
# Set required env vars (see server docs above)
npm start
```

## Development

```bash
cd <server-name>
npm install
npm run dev     # Watch mode with tsx
npm test        # Run vitest
npm run lint    # ESLint checks
```

## MCP Client Configuration

### Claude Desktop (claude_desktop_config.json)

```json
{
  "mcpServers": {
    "wazuh": {
      "command": "node",
      "args": ["/path/to/wazuh-mcp/dist/index.js"],
      "env": {
        "WAZUH_URL": "https://wazuh:55000",
        "WAZUH_USER": "wazuh-wui",
        "WAZUH_PASSWORD": "your-password"
      }
    },
    "thehive": {
      "command": "node",
      "args": ["/path/to/thehive-mcp/dist/index.js"],
      "env": {
        "THEHIVE_URL": "http://thehive:9000",
        "THEHIVE_API_KEY": "your-api-key"
      }
    }
  }
}
```

### OpenClaw / Any MCP Client

All servers use stdio transport. Point your MCP client to the built `dist/index.js` and provide the required environment variables.
