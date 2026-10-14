#!/usr/bin/env bash
# bulk-push-dns.sh — push DNS config to the fleet, one platform-correct
# command sequence per device family. Uses the local admin account, since
# it's guaranteed to work via the AAA fallback even where TACACS+/RADIUS
# is broken or mid-rollout.
#
# Usage:
#   ./bulk-push-dns.sh --test <ip>     push to ONE device only, print result
#   ./bulk-push-dns.sh                 push to every device in DEVICES below
#
# SD-WAN edges (Gret-Edge/BelvEdge/Q-SDWANedge) are deliberately excluded —
# their config is vManage-templated and a local CLI push risks being
# silently reverted on the next template push. Handle those via a CLI
# Add-on Feature Template in vManage instead.
set -u

CRED_FILE="${CRED_FILE:-/root/.admin-cred}"
if [[ ! -f "$CRED_FILE" ]]; then
  echo "ERROR: credential file not found at $CRED_FILE" >&2
  echo "  create it: printf 'ADMIN_USER=admin\nADMIN_PASS=<password>\n' | sudo tee $CRED_FILE && sudo chmod 600 $CRED_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CRED_FILE"

DNS_IP="10.99.0.12"
DOMAIN="lab.internal"

# hostname|ip|category — extend this with the rest of your fleet.
# categories: ios-l3 (VRF DMZ present) | ios-l2 (plain L2 switch, no VRF)
#             nxos | iosxr
DEVICES="
nexus-a|10.99.0.1|nxos
nexus-b|10.99.1.1|nxos
csw1|10.99.1.251|nxos
csw2|10.99.1.252|nxos
corp-pbr-a|10.99.250.250|ios-l3
corp-pbr-b|10.99.250.251|ios-l3
q-edge|10.99.2.1|ios-l3
ce1|10.99.255.253|iosxr
ce2|10.99.255.254|iosxr
asw-a1|10.99.0.150|ios-l2
asw-a2|10.99.0.151|ios-l2
asw-a3|10.99.0.152|ios-l2
asw-b1|10.99.1.150|ios-l2
asw-b2|10.99.1.151|ios-l2
asw-b3|10.99.1.152|ios-l2
dsw-a1|10.99.0.2|ios-l2
dsw-a2|10.99.0.3|ios-l2
dsw-b1|10.99.1.2|ios-l2
dsw-b2|10.99.1.3|ios-l2
q-sw30|10.99.2.30|ios-l2
q-sw31|10.99.2.31|ios-l2
q-sw32|10.99.2.32|ios-l2
q-sw33|10.99.2.33|ios-l2
q-sw34|10.99.2.34|ios-l2
q-sw35|10.99.2.35|ios-l2
q-sw36|10.99.2.36|ios-l2
q-sw37|10.99.2.37|ios-l2
q-sw38|10.99.2.38|ios-l2
q-sw39|10.99.2.39|ios-l2
"

push_ios_l3() {  # VRF-aware IOS/IOS-XE
  local ip="$1"
  sshpass -p "$ADMIN_PASS" ssh -tt -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${ADMIN_USER}@${ip}" << EOF2 2>&1
conf t
ip domain-lookup
ip domain-name $DOMAIN
ip name-server vrf DMZ $DNS_IP
end
wr mem
exit
EOF2
}

push_ios_l2() {  # plain IOS, no VRF (access/distribution switches)
  local ip="$1"
  sshpass -p "$ADMIN_PASS" ssh -tt -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${ADMIN_USER}@${ip}" << EOF2 2>&1
conf t
ip domain-lookup
ip domain-name $DOMAIN
ip name-server $DNS_IP
end
wr mem
exit
EOF2
}

push_nxos() {
  local ip="$1"
  sshpass -p "$ADMIN_PASS" ssh -tt -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${ADMIN_USER}@${ip}" << EOF2 2>&1
conf t
ip domain-lookup
ip domain-name $DOMAIN
ip name-server $DNS_IP use-vrf DMZ
end
copy run start
exit
EOF2
}

push_iosxr() {
  local ip="$1"
  sshpass -p "$ADMIN_PASS" ssh -tt -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${ADMIN_USER}@${ip}" << EOF2 2>&1
conf t
domain name $DOMAIN
domain name-server $DNS_IP
commit
end
exit
EOF2
}

run_one() {
  local hostname="$1" ip="$2" cat="$3" out
  echo "── ${hostname} (${ip}, ${cat}) ──"
  case "$cat" in
    ios-l3) out="$(push_ios_l3 "$ip")" ;;
    ios-l2) out="$(push_ios_l2 "$ip")" ;;
    nxos)   out="$(push_nxos "$ip")" ;;
    iosxr)  out="$(push_iosxr "$ip")" ;;
    *) echo "  unknown category '$cat' — skipped"; return 1 ;;
  esac
  if grep -qiE "invalid|error|% |denied|refused" <<< "$out"; then
    echo "  [WARN] possible error — review manually:"
    sed 's/^/    /' <<< "$out" | tail -15
  else
    echo "  [ OK ]"
  fi
}

if [[ "${1:-}" == "--test" && -n "${2:-}" ]]; then
  target="$2"
  line="$(grep "|${target}|" <<< "$DEVICES")"
  [[ -z "$line" ]] && { echo "no device with IP $target in the list" >&2; exit 1; }
  IFS='|' read -r h i c <<< "$line"
  run_one "$h" "$i" "$c"
  exit 0
fi

echo "== SD-WAN edges skipped — push DNS via vManage CLI Add-on template instead =="
echo "   (Gret-Edge, BelvEdge, Q-SDWANedge)"
echo

while IFS='|' read -r h i c; do
  [[ -z "$h" ]] && continue
  run_one "$h" "$i" "$c"
done <<< "$DEVICES"
