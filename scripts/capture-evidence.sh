#!/usr/bin/env bash
# Capture proof-of-operation into docs/evidence/. Uses the read-only account,
# authenticating via sshpass against a credential file (never hardcoded here).
set -u

OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/docs/evidence}"
CRED_FILE="${CRED_FILE:-/root/.evidence-cred}"

if [[ ! -f "$CRED_FILE" ]]; then
  echo "ERROR: credential file not found at $CRED_FILE" >&2
  echo "  create it: printf 'EVIDENCE_USER=oxidized\nEVIDENCE_PASS=<password>\n' | sudo tee $CRED_FILE && sudo chmod 600 $CRED_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CRED_FILE"

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass not installed. Run: sudo apt install sshpass" >&2
  exit 1
fi

mkdir -p "$OUT"
STAMP="$(date -u '+%Y-%m-%d %H:%MZ')"

run() {  # run <ip> <label> <commands...>
  local ip="$1" label="$2"; shift 2
  local f="$OUT/${label}.md"
  { echo "# ${label}"; echo; echo "_Captured ${STAMP}_"; echo; } > "$f"
  for cmd in "$@"; do
    echo "## \`${cmd}\`" >> "$f"; echo '```' >> "$f"
    sshpass -p "$EVIDENCE_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "${EVIDENCE_USER}@${ip}" "${cmd}" >> "$f" 2>&1 || echo "(unreachable)" >> "$f"
    echo '```' >> "$f"; echo >> "$f"
  done
}

run 10.99.0.1     nexus-a-routing  "show ip ospf neighbors vrf CISCO-CORP" \
                                   "show ip ospf database summary vrf CISCO-CORP" \
                                   "show ip route summary vrf CISCO-CORP"
run 10.99.250.250 pbr-a-services   "show ip pim neighbor" "show ip mroute" \
                                   "show ip msdp summary" "show crypto session" \
                                   "show ip sla summary" "show track brief" \
                                   "show policy-map interface GigabitEthernet2"
run 10.99.2.1     q-edge-branch    "show flow monitor FNF-MONITOR statistics" \
                                   "show policy-map control-plane"
echo "evidence written to $OUT"
