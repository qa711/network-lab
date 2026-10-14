#!/usr/bin/env bash
#
# sanitize-configs.sh — strip secrets from network configs before publishing
#
# Reads a directory of device configs (or a single combined export) and writes
# a redacted copy safe to push to a public repository.
#
# Usage:
#   ./sanitize-configs.sh -i /var/lib/oxidized/configs -o ./public/configs
#   ./sanitize-configs.sh -i all-oxidized-configs.txt -o ./public/ --audit
#
#   --audit    after sanitizing, re-scan the OUTPUT and fail loudly if any
#              known-secret pattern survived. Always run this before pushing.
#
# Design notes:
#   * Replaces secrets with stable placeholders (<TACACS-KEY>) rather than
#     deleting lines, so the published config still reads as a real config.
#   * Public/WAN IPs are rewritten to TEST-NET-1 (RFC 5737) so the topology
#     still makes sense without exposing your circuit.
#   * RFC1918 lab addressing is PRESERVED — it's the whole point of publishing.
#
set -u

IN=""; OUT=""; AUDIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--in)    IN="$2"; shift 2 ;;
    -o|--out)   OUT="$2"; shift 2 ;;
    --audit)    AUDIT=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
[[ -n "$IN" && -n "$OUT" ]] || { echo "usage: $0 -i <file|dir> -o <dir> [--audit]" >&2; exit 64; }
[[ -e "$IN" ]] || { echo "input not found: $IN" >&2; exit 66; }

# ── things that must never be published ────────────────────────────────
# Edit PUBLIC_IPS to match your own WAN address(es).
PUBLIC_IPS=(
  "203.0.113.10"        # home WAN / IPsec local ID
)

# Your own names (personal domain, old site names) are kept out of this file, so
# publishing the script does not publish them. They live in scripts/.sanitize-private,
# which git ignores.
PRIVATE_SED=()
PRIVATE_FILE="$(dirname "$0")/.sanitize-private"
if [[ -f "$PRIVATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$PRIVATE_FILE"
else
  echo "note: $PRIVATE_FILE not found, so no personal names are scrubbed or audited" >&2
fi

mkdir -p "$OUT"

scrub() {   # stdin -> stdout
  sed -E \
    `# ---------- shared secrets: TACACS+ / RADIUS ----------` \
    -e 's/^([[:space:]]*key[[:space:]]+)[0-9][[:space:]]+"?[^"[:space:]]+"?/\1<REDACTED-KEY>/' \
    -e 's/^([[:space:]]*key[[:space:]]+)(chars[[:space:]]+)?[^0-9[:space:]][^[:space:]]*/\1<REDACTED-KEY>/' \
    -e 's/(tacacs-server[[:space:]]+host[[:space:]]+[0-9.]+[[:space:]]+key[[:space:]]+)[0-9]?[[:space:]]*"?[^"[:space:]]+"?/\1<TACACS-KEY>/' \
    -e 's/(radius-server[[:space:]]+host[[:space:]]+[0-9.]+.*[[:space:]]key[[:space:]]+)[^[:space:]]+/\1<RADIUS-KEY>/' \
    -e 's/(tacacs-server[[:space:]]+key[[:space:]]+)[0-9]?[[:space:]]*"?[^"[:space:]]+"?/\1<TACACS-KEY>/' \
    `# ---------- local credentials ----------` \
    -e 's/(username[[:space:]]+[^[:space:]]+.*[[:space:]](password|secret)[[:space:]]+)[0-9][[:space:]]+[^[:space:]]+/\1<REDACTED>/' \
    -e 's/(username[[:space:]]+[^[:space:]]+.*[[:space:]](password|secret)[[:space:]]+)[^0-9[:space:]][^[:space:]]*/\1<REDACTED>/' \
    -e 's/^([[:space:]]*(enable[[:space:]]+)?(secret|password)[[:space:]]+)[0-9][[:space:]]+[^[:space:]]+/\1<REDACTED>/' \
    -e 's/^([[:space:]]*(enable[[:space:]]+)?(secret|password)[[:space:]]+)[^0-9[:space:]][^[:space:]]*/\1<REDACTED>/' \
    `# ---------- SNMP ----------` \
    -e 's/(snmp-server[[:space:]]+community[[:space:]]+)[^[:space:]]+/\1<SNMP-COMMUNITY>/' \
    -e 's/(snmp-server[[:space:]]+host[[:space:]]+[0-9.]+.*(version[[:space:]]+2c|traps|informs)[[:space:]]+)[^[:space:]]+/\1<SNMP-COMMUNITY>/' \
    -e 's/(snmp-server[[:space:]]+user[[:space:]]+[^[:space:]]+.*(auth|priv)[[:space:]]+[^[:space:]]+[[:space:]]+)[^[:space:]]+/\1<SNMP-V3-PASS>/g' \
    -e 's/0x[0-9a-fA-F]{16,}/<SNMP-V3-KEY>/g' \
    `# ---------- IKE / IPsec ----------` \
    -e 's/(crypto[[:space:]]+isakmp[[:space:]]+key[[:space:]]+)([0-9][[:space:]]+)?[^[:space:]]+/\1<PSK>/' \
    -e 's/(pre-shared-key([[:space:]]+(local|remote))?[[:space:]]+)([0-9][[:space:]]+)?[^[:space:]]+/\1<PSK>/' \
    `# ---------- NTP / BGP / OSPF auth ----------` \
    -e 's/(ntp[[:space:]]+authentication-key[[:space:]]+[0-9]+[[:space:]]+md5[[:space:]]+)[^[:space:]]+/\1<NTP-KEY>/' \
    -e 's/(message-digest-key[[:space:]]+[0-9]+[[:space:]]+md5[[:space:]]+)[0-9]?[[:space:]]*[^[:space:]]+/\1<OSPF-KEY>/' \
    -e 's/(authentication-key[[:space:]]+)[0-9]?[[:space:]]*[^[:space:]]+/\1<AUTH-KEY>/' \
    `# ---------- key chains / EIGRP / BGP / DMVPN / OSPFv3 auth (ENARSI phases) ----------` \
    -e 's/(key-string[[:space:]]+).*/\1<KEY-STRING>/' \
    -e 's/(authentication[[:space:]]+mode[[:space:]]+hmac-sha-256[[:space:]]+).*/\1<AUTH-KEY>/' \
    -e 's/(neighbor[[:space:]]+[^[:space:]]+[[:space:]]+password[[:space:]]+).*/\1<BGP-PASSWORD>/' \
    -e 's/(nhrp[[:space:]]+authentication[[:space:]]+).*/\1<NHRP-KEY>/' \
    -e 's/(authentication[[:space:]]+ipsec[[:space:]]+spi[[:space:]]+[0-9]+[[:space:]]+(md5|sha1)[[:space:]]+).*/\1<IPSEC-KEY>/' \
    `# ---------- wireguard / misc base64 keys ----------` \
    -e 's/((PrivateKey|PublicKey|PresharedKey)[[:space:]]*=[[:space:]]*)[A-Za-z0-9+/]{42,}=*/\1<WG-KEY>/' \
    `# ---------- contact / serials ----------` \
    -e 's/(snmp-server contact[[:space:]]+)[^[:space:]]+/\1<CONTACT>/' \
    -e 's/(license udi pid [^[:space:]]+ sn )[A-Za-z0-9]+/\1<SERIAL>/'
}

strip_certs() {   # remove PKI blobs entirely - they are long and pointless
  awk '
    /crypto pki certificate chain|certificate self-signed|certificate ca |-----BEGIN/ {inblob=1; print "  <CERTIFICATE-REDACTED>"; next}
    inblob && (/^[[:space:]]*quit[[:space:]]*$/ || /-----END/) {inblob=0; next}
    inblob {next}
    {print}
  '
}

mask_public_ips() {
  local f=cat
  for ip in "${PUBLIC_IPS[@]}"; do
    f="$f | sed -E 's/\b${ip//./\\.}\b/203.0.113.10/g'"
  done
  eval "$f"
}

scrub_private() {   # your own rules from .sanitize-private, if any
  if (( ${#PRIVATE_SED[@]} )); then sed -E "${PRIVATE_SED[@]}"; else cat; fi
}

process() {  # $1=src  $2=dst
  scrub < "$1" | scrub_private | strip_certs | mask_public_ips > "$2"
}

count=0
if [[ -d "$IN" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$IN"/}"
    mkdir -p "$OUT/$(dirname "$rel")"
    process "$f" "$OUT/$rel"
    count=$((count+1))
  done < <(find "$IN" -type f ! -path '*/.git/*' -print0)
else
  process "$IN" "$OUT/$(basename "$IN")"
  count=1
fi
echo "sanitized $count file(s) -> $OUT"

# ── audit: prove nothing leaked ────────────────────────────────────────
if [[ "$AUDIT" -eq 1 ]]; then
  echo ""
  echo "── audit: scanning OUTPUT for surviving secrets ──"
  leaks=0
  check() {  # $1=label  $2=ERE
    local hits
    # exclude placeholders, and keyword-only lines that contain no actual secret
    hits="$(grep -rEn "$2" "$OUT" 2>/dev/null \
            | grep -vE '<(REDACTED|TACACS-KEY|RADIUS-KEY|SNMP-COMMUNITY|SNMP-V3-PASS|PSK|NTP-KEY|OSPF-KEY|AUTH-KEY|WG-KEY|CERTIFICATE-REDACTED)' \
            | grep -vE 'password (strength-check|encryption|policy|expir|lock|min-|upper|lower|digit)' \
            | grep -vE 'service password-encryption|no service password|password-policy|key config-key|key chain|key-string <' \
            || true)"
    if [[ -n "$hits" ]]; then
      echo "  [LEAK] $1"; sed 's/^/      /' <<< "$hits" | head -5; leaks=$((leaks+1))
    else
      echo "  [ ok ] $1"
    fi
  }
  check "TACACS/RADIUS keys"      '^[[:space:]]*key [0-9A-Za-z]'
  check "local passwords/secrets" '(password|secret) [0-9]? *[A-Za-z0-9]'
  check "SNMP communities"        'snmp-server community [A-Za-z0-9]'
  check "IKE pre-shared keys"     '(isakmp key|pre-shared-key) +[A-Za-z0-9]'
  check "certificate material"    '(-----BEGIN|certificate self-signed [0-9])'
  check "SNMPv3 localized keys"   '0x[0-9a-fA-F]{16,}'
  check "snmp contact"            'snmp-server contact [^<]'
  check "key-string values"       'key-string +[^<[:space:]]'
  check "EIGRP SHA-256 passwords" 'authentication mode hmac-sha-256 +[^<[:space:]]'
  check "BGP neighbor passwords"  'neighbor +[^[:space:]]+ +password +[^<[:space:]]'
  check "NHRP auth strings"       'nhrp authentication +[^<[:space:]]'
  check "OSPF IPsec keys"         'authentication ipsec spi +[0-9]+ +(md5|sha1) +[^<[:space:]]'
  if declare -F private_checks >/dev/null; then private_checks; fi
  for ip in "${PUBLIC_IPS[@]}"; do
    check "public IP $ip" "$(sed 's/\./\\./g' <<< "$ip")"
  done
  echo ""
  if [[ "$leaks" -gt 0 ]]; then
    echo "✗ $leaks category(ies) still contain secrets — DO NOT PUBLISH"; exit 2
  fi
  echo "✓ audit clean — safe to publish"
fi
