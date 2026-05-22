# S³ Stack Architecture

## Design Principles

1. **Modular.** Each MCP server is independent. Use one, some, or all.
2. **Consistent.** All servers follow the same TypeScript patterns, config approach, and error handling.
3. **Demo-ready.** Mock data generators let anyone try it without real infrastructure.
4. **Production-proven.** Playbooks and cases come from real SOC work, not labs.

---

## Component Overview

### Detection Layer

#### Wazuh (SIEM + Vulnerability Management)

The central nervous system of the stack. Wazuh Manager aggregates logs from endpoints, network sensors, and cloud sources, then applies 15,000+ correlation rules to generate alerts.

| Attribute | Value |
|-----------|-------|
| Role | Log aggregation, correlation, alerting, vulnerability scanning |
| API Port | 55000 (HTTPS, JWT auth) |
| Dashboard Port | 443 (HTTPS) |
| Agent Port | 1514 (TCP, encrypted) |
| Enrollment Port | 1515 (TCP) |
| Backend | Wazuh Indexer (OpenSearch fork), port 9200 |
| VM Specs (recommended) | 4 vCPU, 8 GB RAM, 100 GB storage |
| Docker Image | `wazuh/wazuh-manager:4.9.0` |

**Key capabilities:**
- Real-time log analysis and correlation
- File integrity monitoring (syscheck)
- Rootkit detection (rootcheck)
- System inventory (syscollector)
- Vulnerability detection (CVE scanning via NVD)
- Security Configuration Assessment (CIS benchmarks)
- Active response (automated blocking, script execution)

#### Zeek (Network Security Monitor)

Passive network traffic analyzer that produces detailed, structured logs for every protocol it understands. Runs on a dedicated sensor with access to a network tap or SPAN port.

| Attribute | Value |
|-----------|-------|
| Role | Deep packet inspection, protocol metadata logging |
| Output | Log files (JSON or TSV) in configurable directory |
| Default Log Dir | `/opt/zeek/logs/current/` |
| VM Specs (recommended) | 4 vCPU, 8 GB RAM, 200 GB storage (log retention) |
| Deployment | Bare metal or VM on sensor host (not Docker) |

**Key log types:**
- `conn.log`: Every TCP/UDP/ICMP connection (5-tuple, bytes, duration)
- `dns.log`: All DNS queries and responses
- `http.log`: HTTP requests with method, URI, host, user agent, response code
- `ssl.log`: TLS handshakes with SNI, certificate chain, JA3/JA3S hashes
- `files.log`: Extracted file metadata with MD5/SHA1/SHA256
- `notice.log`: Zeek-generated alerts (scan detection, SSL issues, etc.)
- `smtp.log`: Email metadata (sender, recipient, subject)
- `ssh.log`: SSH connection details and authentication results

#### Suricata (IDS/IPS)

Signature-based intrusion detection and prevention system. Processes the same traffic as Zeek but focuses on matching known-bad patterns from rule sets (ET Open, ET Pro, Snort community).

| Attribute | Value |
|-----------|-------|
| Role | Signature-based detection, protocol anomaly detection |
| Output | EVE JSON (`/var/log/suricata/eve.json`) |
| VM Specs (recommended) | 4 vCPU, 4 GB RAM, 50 GB storage |
| Deployment | Bare metal or VM on sensor host (not Docker) |

**Key capabilities:**
- 40,000+ signatures (ET Open ruleset)
- JA3/JA4 TLS fingerprinting
- Protocol anomaly detection
- Inline IPS mode (drop malicious traffic)
- File extraction with hash computation
- EVE JSON unified output (alerts, flows, DNS, HTTP, TLS, fileinfo)

**Zeek vs. Suricata:** Zeek tells you what happened (protocol metadata). Suricata tells you what is bad (signature matches). Use both.

---

### Intelligence Layer

#### MISP (Threat Intelligence Platform)

Central repository for indicators of compromise (IOCs). Aggregates threat intelligence from external feeds, internal sightings, and analyst contributions. Shares intelligence with detection tools and partner organizations.

| Attribute | Value |
|-----------|-------|
| Role | IOC storage, correlation, sharing, feed aggregation |
| API Port | 443 (HTTPS, API key auth) |
| Backend | MySQL/MariaDB + Redis |
| VM Specs (recommended) | 2 vCPU, 4 GB RAM, 50 GB storage |
| Docker Image | `coolacid/misp-docker:latest` |

**Key capabilities:**
- Event and attribute management (IP, domain, hash, email, URL, YARA, Sigma)
- Automatic correlation across events
- Taxonomy tagging (TLP, ATT&CK, admiralty code)
- Warninglists (filter known false positives: CDNs, cloud providers, RFC1918)
- STIX/TAXII export for tool integration
- Feed synchronization (CIRCL, Abuse.ch, AlienVault OTX)

#### MITRE ATT&CK (Adversary Framework)

Offline knowledge base of adversary tactics, techniques, and procedures. Provides context for mapping observed behaviors to known threat actor patterns.

| Attribute | Value |
|-----------|-------|
| Role | TTP mapping, detection coverage analysis, threat attribution |
| Data Source | STIX 2.1 bundles (downloaded from MITRE, cached locally) |
| Storage | ~50 MB on disk |
| Update Frequency | Monthly (or on demand) |

**Key data:**
- 14 tactics (Reconnaissance through Impact)
- 200+ techniques with sub-techniques
- 140+ threat groups with technique associations
- 600+ software entries (malware and tools)
- Detection data sources and components
- Mitigation recommendations per technique

---

### Analysis Layer

#### Cortex (Observable Analysis Engine)

Automated enrichment and analysis engine. When an analyst (or AI) submits an observable, Cortex fans it out to multiple analyzers simultaneously and returns consolidated results.

| Attribute | Value |
|-----------|-------|
| Role | Automated observable enrichment, response actions |
| API Port | 9001 (HTTP, API key auth) |
| Backend | Elasticsearch |
| VM Specs (recommended) | 2 vCPU, 4 GB RAM, 20 GB storage |
| Docker Image | `thehiveproject/cortex:3.1.7` |

**Key capabilities:**
- 100+ analyzer integrations (VirusTotal, AbuseIPDB, Shodan, Whois, MaxMind, etc.)
- Responder actions (send email, block IP on firewall, disable AD account)
- Job management with status tracking
- Rate limiting and API key management per analyzer
- Report caching to reduce duplicate API calls

---

### Response Layer

#### TheHive (Incident Response Platform)

Case management system for the full incident lifecycle. Receives alerts from detection tools, supports analyst workflows, and tracks evidence through resolution.

| Attribute | Value |
|-----------|-------|
| Role | Case management, alert triage, task tracking, observable management |
| API Port | 9000 (HTTP, API key auth) |
| Backend | Cassandra (data) + Elasticsearch (index) + MinIO (files) |
| VM Specs (recommended) | 4 vCPU, 8 GB RAM, 50 GB storage |
| Docker Image | `strangebee/thehive:5.3` |

**Key capabilities:**
- Alert ingestion from multiple sources (Wazuh, Suricata, email, manual)
- Case lifecycle: New, InProgress, Resolved, Closed
- Task assignment with checklists and due dates
- Observable tracking with Cortex integration (one-click analysis)
- Custom fields and templates per case type
- Merge and link related cases
- Full audit trail and timeline

---

### Commercial Integrations

#### Rapid7 InsightVM

Enterprise vulnerability management platform. Complements Wazuh vulnerability scanning with agent-based and network-based scanning, risk scoring, and remediation tracking.

| Attribute | Value |
|-----------|-------|
| Role | Vulnerability scanning, asset discovery, risk scoring |
| API Port | 3780 (HTTPS) |
| Deployment | On-premises console or cloud-hosted |

#### Sophos Central

Cloud-managed endpoint protection platform. Provides antivirus, EDR, and response capabilities. The MCP server enables AI-driven endpoint queries and isolation actions.

| Attribute | Value |
|-----------|-------|
| Role | Endpoint protection, detection, isolation |
| API | Cloud REST API (api.central.sophos.com) |
| Auth | OAuth2 (client ID + secret) |
| Deployment | Cloud-managed, agents on endpoints |

---

## Infrastructure Layout

### Recommended VM Allocation (Proxmox/ESXi)

| VM | vCPU | RAM | Disk | Purpose |
|----|------|-----|------|---------|
| wazuh-manager | 4 | 8 GB | 100 GB | Wazuh Manager + Indexer + Dashboard |
| sensor-01 | 4 | 8 GB | 200 GB | Zeek + Suricata (network tap) |
| thehive | 4 | 8 GB | 50 GB | TheHive + Cortex + Cassandra + ES |
| misp | 2 | 4 GB | 50 GB | MISP + MySQL + Redis |
| mcp-gateway | 2 | 4 GB | 20 GB | All 9 MCP servers (Node.js) |
| **Total** | **16** | **32 GB** | **420 GB** | |

For smaller deployments, TheHive and MISP can share a single VM. The MCP gateway is lightweight and can run on any existing host.

### Network Architecture

```
┌──────────────────────────────────────────────────┐
│                  Management VLAN (198.51.100.0/24)   │
│                                                   │
│  wazuh-manager  .10    thehive     .20            │
│  misp           .30    mcp-gateway .40            │
│                                                   │
└──────────────────────┬───────────────────────────┘
                       │
                   Core Switch
                       │
            ┌──────────┴──────────┐
            │   SPAN / TAP Port   │
            │                     │
            ▼                     │
┌────────────────────┐            │
│ Sensor VLAN        │            │
│ (198.51.100.0/24)      │            │
│                     │            │
│ sensor-01  .10      │            │
│ (Zeek + Suricata)   │            │
└─────────────────────┘            │
                                   │
                       ┌───────────┴───────────┐
                       │   Production Network   │
                       │   (monitored traffic)  │
                       └────────────────────────┘
```

### Port Summary

| Port | Service | Protocol | Notes |
|------|---------|----------|-------|
| 443 | Wazuh Dashboard, MISP, Sophos API | HTTPS | Web interfaces and APIs |
| 1514 | Wazuh Agent | TCP | Agent to Manager communication |
| 1515 | Wazuh Enrollment | TCP | New agent registration |
| 3780 | Rapid7 InsightVM | HTTPS | Vulnerability scanner API |
| 9000 | TheHive | HTTP | Case management API |
| 9001 | Cortex | HTTP | Analysis engine API |
| 9002 | MinIO | HTTP | Object storage (TheHive files) |
| 9042 | Cassandra | TCP | TheHive data backend |
| 9200 | Elasticsearch/OpenSearch | HTTPS | Indexing backend |
| 55000 | Wazuh Manager API | HTTPS | SIEM management API |

---

## MCP Server Architecture

All nine servers follow the same internal pattern:

```
<tool>-mcp/
  src/
    index.ts          # Server entry, tool registration via @modelcontextprotocol/server
    config.ts         # Env var config with Zod validation
    client.ts         # REST/log API client (axios for API, readline for logs)
    tools/            # Tool implementations (one file per category)
    resources.ts      # MCP resources (optional)
    prompts.ts        # MCP prompts (optional)
    types.ts          # TypeScript type definitions
  tests/
    *.test.ts         # Vitest tests with mocked responses
  package.json
  tsconfig.json       # Extends ../tsconfig.base.json
  README.md
  .env.example
```

### Shared Conventions

- **Config:** Environment variables, validated with Zod at startup. Fail fast on missing config.
- **Auth:** Bearer tokens for API-based tools, file paths for log-based tools.
- **Errors:** Consistent error wrapping with tool name, operation, and original error message.
- **Types:** Full TypeScript strict mode. No `any` types.
- **Testing:** Vitest with mocked API responses. No live API calls in tests.
- **Transport:** stdio (primary for CLI/desktop clients), Streamable HTTP (optional for web clients).
