#!/usr/bin/env bash
# scripts/components/wazuh/integrate.sh
# Runs on the Proxmox HOST after all components are deployed.
# Wires Wazuh alerts to a TheHive webhook.

set -euo pipefail

: "${SOC_STATE_DIR:?SOC_STATE_DIR must be set}"

log() { printf '[wazuh-integrate] %s\n' "$*"; }

WAZUH_STATE="${SOC_STATE_DIR}/state/wazuh.json"
THEHIVE_STATE="${SOC_STATE_DIR}/state/thehive-cortex.json"

if [[ ! -f "${WAZUH_STATE}" ]]; then
  log "wazuh state missing, skipping integration"
  exit 0
fi
wazuh_status="$(jq -r '.status // empty' "${WAZUH_STATE}")"
if [[ "${wazuh_status}" != "deployed" ]]; then
  log "wazuh status=${wazuh_status}, skipping"
  exit 0
fi
wazuh_vmid="$(jq -r '.lxc.vmid // empty' "${WAZUH_STATE}")"
[[ -n "${wazuh_vmid}" ]] || { log "wazuh has no VMID, skipping"; exit 0; }

if [[ ! -f "${THEHIVE_STATE}" ]]; then
  log "TheHive state missing, skipping Wazuh -> TheHive webhook"
  exit 0
fi
thehive_status="$(jq -r '.status // empty' "${THEHIVE_STATE}")"
if [[ "${thehive_status}" != "deployed" ]]; then
  log "TheHive status=${thehive_status}, skipping webhook wiring"
  exit 0
fi

thehive_url="$(jq -r '.thehive.url // empty' "${THEHIVE_STATE}")"
thehive_key="$(jq -r '.thehive.api_key // empty' "${THEHIVE_STATE}")"
[[ -n "${thehive_url}" && -n "${thehive_key}" ]] || {
  log "missing TheHive URL or API key, skipping"
  exit 0
}
# Both values are interpolated into a heredoc and a sed expression below;
# reject anything outside the charset our own deploys produce.
if [[ ! "${thehive_url}" =~ ^https?://[A-Za-z0-9_.:-]+(/[A-Za-z0-9_./-]*)?$ ]]; then
  log "TheHive URL has unexpected characters, refusing to wire: ${thehive_url}"
  exit 1
fi
if [[ ! "${thehive_key}" =~ ^[A-Za-z0-9_+=./-]+$ ]]; then
  log "TheHive API key has unexpected characters, refusing to wire"
  exit 1
fi

log "configuring Wazuh -> TheHive webhook (vmid=${wazuh_vmid} -> ${thehive_url})"

# Push the integration script into the Wazuh LXC
INTEG_PY="/tmp/custom-thehive.py"
trap 'rm -f "${INTEG_PY}"' EXIT
cat > "${INTEG_PY}" <<PYEOF
#!/usr/bin/env python3
"""custom-thehive: forward Wazuh alerts to TheHive 5."""
import json, sys, urllib.request, urllib.error

THEHIVE_URL = "${thehive_url}"
THEHIVE_API_KEY = "${thehive_key}"

def main():
    alert_file = sys.argv[1]
    with open(alert_file) as f:
        alert = json.load(f)
    severity_map = {1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 2, 7: 2, 8: 2, 9: 3, 10: 3, 11: 3, 12: 4, 13: 4, 14: 4, 15: 4}
    level = int(alert.get("rule", {}).get("level", 3))
    sev = severity_map.get(level, 2)
    payload = {
        "type": "wazuh",
        "source": "Wazuh SIEM",
        "sourceRef": str(alert.get("id", "unknown")),
        "title": alert.get("rule", {}).get("description", "Wazuh Alert"),
        "description": json.dumps(alert, indent=2),
        "severity": sev,
        "tlp": 2,
        "tags": ["wazuh", "s3-stack"]
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{THEHIVE_URL}/api/v1/alert",
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bearer {THEHIVE_API_KEY}",
            "Content-Type": "application/json",
        },
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as e:
        # Treat 4xx/5xx as soft failures so Wazuh doesn't retry-storm
        print(f"thehive webhook returned {e.code}", file=sys.stderr)

if __name__ == "__main__":
    main()
PYEOF
pct push "${wazuh_vmid}" "${INTEG_PY}" /var/ossec/integrations/custom-thehive.py
pct exec "${wazuh_vmid}" -- chmod 750 /var/ossec/integrations/custom-thehive.py
pct exec "${wazuh_vmid}" -- chown root:wazuh /var/ossec/integrations/custom-thehive.py

# Insert <integration> block into ossec.conf (idempotent)
if ! pct exec "${wazuh_vmid}" -- grep -q "custom-thehive" /var/ossec/etc/ossec.conf; then
  pct exec "${wazuh_vmid}" -- bash -c "sed -i '/<\/ossec_config>/i\\
  <integration>\\
    <name>custom-thehive</name>\\
    <hook_url>${thehive_url}</hook_url>\\
    <level>8</level>\\
    <alert_format>json</alert_format>\\
  </integration>' /var/ossec/etc/ossec.conf"
  pct exec "${wazuh_vmid}" -- systemctl restart wazuh-manager
fi
rm -f "${INTEG_PY}"

# Mark integration in state
state_set_file="${SOC_STATE_DIR}/state/wazuh.json"
if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq '.integrations = ((.integrations // []) + [{to: "thehive-cortex", type: "webhook", status: "configured"}] | unique_by(.to + .type))' "${state_set_file}" > "${tmp}"
  mv "${tmp}" "${state_set_file}"
fi

log "Wazuh -> TheHive webhook configured"
exit 0
