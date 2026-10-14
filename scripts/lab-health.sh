#!/usr/bin/env bash
#
# lab-health.sh — health check + self-heal for the EVE-NG lab support stack
#
#   Akvorado (NetFlow)  ·  FreeRADIUS (+TOTP)  ·  tac_plus (TACACS+)  ·  SNMP
#
# Usage:
#   ./lab-health.sh              check only, report, exit 0/1/2
#   ./lab-health.sh --fix        attempt remediation of known-safe problems
#   ./lab-health.sh --deep       add end-to-end TOTP auth test (see note below)
#   ./lab-health.sh --quiet      only print WARN/FAIL lines (good for cron)
#
# Exit codes:  0 = all green   1 = warnings only   2 = one or more failures
#
# NOTE: deliberately NOT 'pipefail'. Several checks pipe a long-running command
# into 'grep -q', which exits on first match and SIGPIPEs the upstream command
# (exit 141). With pipefail that 141 becomes the pipeline's status and the check
# silently reports 'not installed' for a service that is actually running.
set -u

# Secrets live in a root-only file, never in this script or the repo:
#   /etc/lab-health.env   SNMP_COMMUNITY=...   RADIUS_LOCAL_SECRET=...
# Precedence: command-line/systemd env  >  env file  >  defaults below.
LAB_HEALTH_ENV="${LAB_HEALTH_ENV:-/etc/lab-health.env}"
if [[ -r "$LAB_HEALTH_ENV" ]]; then
  while IFS='=' read -r _k _v; do
    [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    _v="${_v%\"}"; _v="${_v#\"}"; _v="${_v%\'}"; _v="${_v#\'}"
    [[ -z "${!_k:-}" ]] && printf -v "$_k" '%s' "$_v"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$LAB_HEALTH_ENV")
  unset _k _v
fi

# ─────────────────────────────── config ────────────────────────────────
# Override any of these from the environment, e.g.  NMS_IP=10.99.0.20 ./lab-health.sh
AKV_DIR="${AKV_DIR:-/root/akvorado}"          # dir containing docker-compose.yml
NMS_IP="${NMS_IP:-10.99.0.12}"
SNMP_COMMUNITY="${SNMP_COMMUNITY:-}"
SNMP_TARGETS=("10.99.250.250" "10.99.2.1")    # PBR-A Lo99, Q-EDGE — add more as you go
RADIUS_LOCAL_SECRET="${RADIUS_LOCAL_SECRET:-testing123}"   # clients.conf 'localhost'
TOTP_USER="${TOTP_USER:-netadmin}"
TOTP_SECRET_FILE="${TOTP_SECRET_FILE:-/var/lib/freeradius/googleauth/${TOTP_USER}}"
FLOW_STALE_WARN_MIN="${FLOW_STALE_WARN_MIN:-30}"           # idle lab => stale is OK-ish
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"

# Ports we care about:  proto:port:description
PORTS=(
  "u:2055:NetFlow  (Akvorado inlet)"
  "t:49:TACACS+  (tac_plus)"
  "u:1812:RADIUS auth  (FreeRADIUS)"
  "u:1813:RADIUS acct  (FreeRADIUS)"
)
# Processes that are *legitimate* owners of a port (regex, matched per-port below)
SAFE_TO_KILL="nfcapd|nfdump|softflowd"        # known squatters --fix may terminate

# ────────────────────────────── plumbing ───────────────────────────────
FIX=0; DEEP=0; QUIET=0
for arg in "$@"; do
  case "$arg" in
    --fix)   FIX=1 ;;
    --deep)  DEEP=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 64 ;;
  esac
done

if [[ -t 1 && "$QUIET" -eq 0 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_DIM=$'\e[2m'; C_HDR=$'\e[1;36m'; C_OFF=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_HDR=""; C_OFF=""
fi

FAILS=0; WARNS=0; FIXES=0; akv_compose=""; inlet_log=""

section() { [[ "$QUIET" -eq 1 ]] || printf '\n%s━━━ %s %s\n' "$C_HDR" "$1" "$C_OFF"; }
ok()      { [[ "$QUIET" -eq 1 ]] || printf ' %s[ OK ]%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
skip()    { [[ "$QUIET" -eq 1 ]] || printf ' %s[SKIP]%s  %s\n' "$C_DIM" "$C_OFF" "$1"; }
warn()    { WARNS=$((WARNS+1)); printf ' %s[WARN]%s  %s\n' "$C_WARN" "$C_OFF" "$1"; }
fail()    { FAILS=$((FAILS+1)); printf ' %s[FAIL]%s  %s\n' "$C_FAIL" "$C_OFF" "$1"; }
hint()    { printf '   %s└─ %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
fixed()   { FIXES=$((FIXES+1)); printf '   %s└─ fixed: %s%s\n' "$C_OK" "$1" "$C_OFF"; }

have()    { command -v "$1" >/dev/null 2>&1; }
unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }
compose_ok()   { ( cd "$AKV_DIR" 2>/dev/null && docker compose config -q ) >/dev/null 2>&1; }
dc()      { ( cd "$AKV_DIR" && docker compose "$@" ); }

[[ $EUID -eq 0 ]] || { echo "must run as root (needs ss -p, docker, systemctl)" >&2; exit 64; }

# ═══════════════════════════════ 1. host ═══════════════════════════════
section "Host"

root_opts="$(findmnt -no OPTIONS / 2>/dev/null)"
if [[ ",${root_opts}," == *",rw,"* ]]; then
  ok "root filesystem is read-write"
else
  fail "root filesystem is READ-ONLY — everything below will misbehave"
  hint "try: mount -o remount,rw /   then check: dmesg | grep -i ext4"
fi

disk_pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [[ -n "$disk_pct" && "$disk_pct" -ge "$DISK_WARN_PCT" ]]; then
  warn "disk usage ${disk_pct}% on / (threshold ${DISK_WARN_PCT}%) — ClickHouse will suffer first"
  hint "reclaim: docker system prune -a --volumes   (careful: drops unused volumes)"
else
  ok "disk usage ${disk_pct:-?}% on / (threshold ${DISK_WARN_PCT}%)"
fi

if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  ok "clock synchronised — TOTP codes will validate"
else
  fail "clock NOT synchronised — every TOTP code will be rejected"
  hint "fix: timedatectl set-ntp true   (and check the phone is on automatic time)"
  if [[ "$FIX" -eq 1 ]]; then
    timedatectl set-ntp true 2>/dev/null && fixed "enabled NTP sync (allow a minute to settle)"
  fi
fi

for svc in systemd-resolved docker; do
  if systemctl is-active --quiet "$svc"; then
    ok "$svc active"
  else
    fail "$svc is NOT active"
    if [[ "$FIX" -eq 1 ]]; then
      systemctl restart "$svc" && fixed "restarted $svc"
    else
      hint "fix: systemctl restart $svc"
    fi
  fi
done

# ══════════════════════════ 2. port ownership ══════════════════════════
# The recurring gremlin: something else grabs 2055 and the Akvorado inlet
# then crash-loops forever on 'address already in use'.
section "Port ownership"

port_owner() {  # $1 = u|t   $2 = port  → prints owning process name, or nothing
  local raw; raw="$(ss -lnp"$1" "sport = :$2" 2>/dev/null)"
  [[ -z "$raw" ]] && return 0
  sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<< "$raw" | head -1
}

inlet_running() {
  [[ -n "$(docker ps --filter 'name=akvorado-akvorado-inlet' --filter 'status=running' -q 2>/dev/null)" ]]
}

for spec in "${PORTS[@]}"; do
  IFS=':' read -r proto port desc <<< "$spec"
  owner="$(port_owner "$proto" "$port")"

  if [[ -z "$owner" ]]; then
    # Nothing holds it. For 2055 that's only OK if Docker is doing iptables-DNAT
    # (userland-proxy disabled) *and* the inlet is actually up.
    if [[ "$port" == "2055" ]] && inlet_running; then
      ok "${proto}/${port} — no host process, inlet container running (iptables DNAT mode)"
    else
      warn "${proto}/${port} free — nothing listening for ${desc}"
    fi
    continue
  fi

  case "$owner" in
    docker-proxy)
      ok "${proto}/${port} held by docker-proxy — ${desc}" ;;
    tac_plus|freeradius|radiusd)
      ok "${proto}/${port} held by ${owner} — ${desc}" ;;
    *)
      if [[ "$owner" =~ ^($SAFE_TO_KILL)$ ]]; then
        fail "${proto}/${port} SQUATTED by ${owner} — ${desc} cannot bind"
        if [[ "$FIX" -eq 1 ]]; then
          pkill -x "$owner" && sleep 1 && fixed "terminated ${owner}"
        else
          hint "fix: pkill -x ${owner}     (or re-run with --fix)"
        fi
      else
        warn "${proto}/${port} held by unexpected process '${owner}' — not touching it"
        hint "investigate: ss -lnp${proto} 'sport = :${port}'"
      fi ;;
  esac
done

# ══════════════════════════ 3. Akvorado stack ══════════════════════════
section "Akvorado"

if ! compose_ok; then
  skip "no usable compose project in $AKV_DIR — set AKV_DIR to the quickstart directory"
else
  # Bring the stack up first if asked; harmless when already running.
  if [[ "$FIX" -eq 1 ]]; then
    dc up -d >/dev/null 2>&1 && FIXES=$((FIXES+1))
  fi

  mapfile -t rows < <(docker ps -a 2>/dev/null --filter 'name=akvorado-' --format '{{.Names}}|{{.Status}}')
  if [[ "${#rows[@]}" -eq 0 ]]; then
    fail "no Akvorado containers exist"
    hint "fix: cd $AKV_DIR && docker compose up -d     (or re-run with --fix)"
  else
    bad=0
    for row in "${rows[@]}"; do
      name="${row%%|*}"; status="${row#*|}"
      short="${name#akvorado-}"; short="${short%-1}"
      case "$status" in
        *"(healthy)"*)   ok  "$short — $status" ;;
        *"(unhealthy)"*) fail "$short — $status"; bad=1 ;;
        Restarting*)     fail "$short — $status  (crash loop)"; bad=1 ;;
        Exited*)         fail "$short — $status"; bad=1 ;;
        Up*)             ok  "$short — $status" ;;   # no healthcheck defined (traefik, kafka-ui)
        *)               warn "$short — $status" ;;
      esac
    done

    # The specific crash-loop we hit twice: container DNS can't resolve the orchestrator.
    inlet_log="$(dc logs --tail=20 akvorado-inlet 2>/dev/null)"
    if [[ "$inlet_log" == *"lookup akvorado-orchestrator"* ]]; then
      fail "inlet cannot resolve 'akvorado-orchestrator' — container DNS is broken"
      hint "usually: systemctl restart systemd-resolved && systemctl restart docker"
      hint "then:    cd $AKV_DIR && docker compose up -d"
      if [[ "$FIX" -eq 1 ]]; then
        systemctl restart systemd-resolved
        systemctl restart docker
        sleep 5
        dc up -d >/dev/null 2>&1 && fixed "restarted resolver + docker, re-created stack"
      fi
    fi

    if [[ "$bad" -eq 1 && "$FIX" -eq 1 ]]; then
      dc up -d >/dev/null 2>&1 && fixed "re-ran 'docker compose up -d'"
    fi
  fi
fi

# ═════════════════════════════ 4. AAA ══════════════════════════════════
section "AAA (TACACS+ / RADIUS)"

# --- tac_plus ---
if unit_exists tac_plus.service; then
  if systemctl is-active --quiet tac_plus; then
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/49" 2>/dev/null; then
      ok "tac_plus active and accepting TCP/49"
    else
      fail "tac_plus service is up but TCP/49 refuses connections"
    fi
  else
    fail "tac_plus is not running"
    hint "note: it forks by default — the unit needs 'tac_plus -G' (foreground) or Type=forking"
    if [[ "$FIX" -eq 1 ]]; then
      systemctl start tac_plus && sleep 1 && systemctl is-active --quiet tac_plus \
        && fixed "started tac_plus"
    fi
  fi
else
  skip "tac_plus not installed"
fi

# --- FreeRADIUS ---
if unit_exists freeradius.service; then
  if ! systemctl is-active --quiet freeradius; then
    fail "freeradius is not running"
    hint "debug it in the foreground:  systemctl stop freeradius && freeradius -X"
    if [[ "$FIX" -eq 1 ]]; then
      systemctl start freeradius && sleep 2 && systemctl is-active --quiet freeradius \
        && fixed "started freeradius"
    fi
  else
    # Liveness probe: deliberately bad credentials. ANY response proves the server
    # is alive and processing — no valid OTP needed, no secrets in the script.
    if have radtest; then
      probe="$(timeout 8 radtest __healthcheck__ __nope__ 127.0.0.1 0 "$RADIUS_LOCAL_SECRET" 2>&1)"
      if grep -q 'Access-Reject' <<< "$probe"; then
        ok "freeradius active and answering (bad-credential probe → Access-Reject, as expected)"
      elif grep -q 'Access-Accept' <<< "$probe"; then
        fail "freeradius ACCEPTED junk credentials — check mods-config/files/authorize"
      else
        fail "freeradius did not respond on 1812 (timeout)"
        hint "check the shared secret for 'client localhost' in clients.conf"
      fi
    else
      skip "radtest not installed (apt install freeradius-utils) — service is up though"
    fi
  fi

  # --- PAM config sanity: the two bugs that actually bit us ---
  if [[ -f /etc/pam.d/radiusd ]]; then
    gauth_line="$(grep -E '^\s*auth.*pam_google_authenticator' /etc/pam.d/radiusd || true)"
    if [[ -n "$gauth_line" ]]; then

      # (a) missing user=freerad → "Failed to change user id to <user>"
      if ! grep -q 'user=freerad' <<< "$gauth_line"; then
        fail "pam_google_authenticator is missing 'user=freerad'"
        hint "without it PAM tries to become '${TOTP_USER}' to read the secret, and can't"
      else
        ok "PAM: user=freerad present (privilege drop handled)"
      fi

      # (b) secret under a systemd-protected path → "Read-only file system" on write-back,
      #     which silently disables TOTP replay protection.
      secret_path="$(grep -oP 'secret=\K[^ ]+' <<< "$gauth_line" | head -1)"
      if [[ "$secret_path" == /etc/* ]]; then
        prot="$(systemctl show freeradius -p ProtectSystem --value 2>/dev/null)"
        rwp="$(systemctl show freeradius -p ReadWritePaths --value 2>/dev/null)"
        if [[ "$prot" == "full" || "$prot" == "strict" ]] && ! grep -q 'googleauth' <<< "$rwp"; then
          warn "TOTP secret lives under /etc but freeradius runs ProtectSystem=${prot}"
          hint "the daemon cannot write back the used-code marker → replay protection is OFF"
          hint "fix: move secrets to /var/lib/freeradius/googleauth and update secret= in /etc/pam.d/radiusd"
        else
          ok "PAM: secret path is writable by the daemon"
        fi
      else
        ok "PAM: secret path outside systemd-protected dirs (${secret_path%/*})"
      fi
    fi
  fi

  # --- optional deep check: real end-to-end TOTP authentication ---
  if [[ "$DEEP" -eq 1 ]]; then
    if ! have oathtool; then
      skip "--deep needs oathtool (apt install oathtool)"
    elif [[ ! -r "$TOTP_SECRET_FILE" ]]; then
      skip "--deep: cannot read $TOTP_SECRET_FILE"
    else
      # NOTE: this lets the box mint its own OTP codes, which weakens the 2nd factor.
      # Fine in a lab; do NOT do this on anything real.
      b32="$(head -1 "$TOTP_SECRET_FILE")"
      code="$(oathtool --totp -b "$b32" 2>/dev/null)"
      out="$(timeout 8 radtest "$TOTP_USER" "$code" 127.0.0.1 0 "$RADIUS_LOCAL_SECRET" 2>&1)"
      if grep -q 'Access-Accept' <<< "$out"; then
        ok "deep: end-to-end TOTP authentication for '${TOTP_USER}' succeeded"
      else
        fail "deep: TOTP authentication for '${TOTP_USER}' failed"
        hint "watch it live:  journalctl -f | grep -i google"
      fi
    fi
  fi
else
  skip "freeradius not installed"
fi

# ═══════════════════════ 5. data plane / probes ════════════════════════
section "Probes"

# --- SNMP: this is also Akvorado's metadata gate. If it fails, flows get dropped. ---
if ! have snmpget; then
  skip "snmpget not installed (apt install snmp)"
elif [[ -z "$SNMP_COMMUNITY" ]]; then
  fail "SNMP probes not run — SNMP_COMMUNITY is not set"
  hint "add SNMP_COMMUNITY=<community> to ${LAB_HEALTH_ENV} (chmod 600)"
else
  for t in "${SNMP_TARGETS[@]}"; do
    name="$(snmpget -v2c -c "$SNMP_COMMUNITY" -t 2 -r 1 -Ovq "$t" 1.3.6.1.2.1.1.5.0 2>/dev/null | tr -d '"')"
    if [[ -n "$name" ]]; then
      ok "SNMP ${t} → ${name}"
    else
      fail "SNMP ${t} no response — Akvorado will DROP this exporter's flows (metadata gate)"
      hint "check the device's SNMP ACL permits ${NMS_IP}, and its community matches SNMP_COMMUNITY in ${LAB_HEALTH_ENV}"
    fi
  done
fi

# --- ClickHouse: are flows actually landing, and from whom? ---
if compose_ok && [[ -n "$(docker ps --filter 'name=akvorado-clickhouse' -q 2>/dev/null)" ]]; then
  # -T is essential: no TTY under systemd/cron.
  res="$(dc exec -T clickhouse clickhouse-client -q \
        "SELECT count(*), ifNull(toUnixTimestamp(max(TimeReceived)),0) FROM flows" 2>/dev/null)"
  cnt="$(awk '{print $1}' <<< "$res")"; ts="$(awk '{print $2}' <<< "$res")"

  if [[ -z "${cnt:-}" ]]; then
    fail "could not query ClickHouse"
  elif [[ "${cnt:-0}" -eq 0 ]]; then
    fail "ClickHouse holds ZERO flows"
    hint "walk it: tcpdump -ni any udp port 2055   then   curl -s http://127.0.0.1:8081/api/v0/outlet/metrics | grep flows_errors"
  else
    age_min=$(( ( $(date +%s) - ts ) / 60 ))
    if [[ "$age_min" -gt "$FLOW_STALE_WARN_MIN" ]]; then
      warn "flows present ($cnt) but newest is ${age_min} min old"
      hint "an idle lab exports nothing — generate traffic, then re-check before worrying"
    else
      ok "flows landing — $cnt total, newest ${age_min} min old"
    fi
  fi

  # Per-exporter breakdown for the last hour — shows at a glance who stopped talking.
  if [[ "$QUIET" -eq 0 ]]; then
    dc exec -T clickhouse clickhouse-client -q \
      "SELECT concat('   · ', toString(ExporterAddress), '  ', ifNull(ExporterName,'?'), '  ', toString(count(*)), ' flows/1h')
       FROM flows WHERE TimeReceived > now() - INTERVAL 1 HOUR
       GROUP BY ExporterAddress, ExporterName ORDER BY ExporterAddress" 2>/dev/null \
      | sed "s/^/${C_DIM}/;s/\$/${C_OFF}/"
  fi

  # Rejected flows: names the gate that's closed (metadata / sampling rate / interfaces).
  errs="$(curl -s --max-time 5 http://127.0.0.1:8081/api/v0/outlet/metrics 2>/dev/null \
          | grep '^akvorado_outlet_core_flows_errors_total' || true)"
  if [[ -n "$errs" ]]; then
    warn "outlet is rejecting some flows:"
    sed 's/^/   · /' <<< "$errs"
    hint "'sampling rate missing' → set default-sampling-rate in outlet.yaml"
    hint "'metadata missing'      → SNMP poll to that exporter's source IP is failing"
  else
    ok "no flows being rejected by the outlet"
  fi
else
  skip "ClickHouse not running — no flow check"
fi

# ══════════════════════════════ summary ════════════════════════════════
printf '\n'
if [[ "$FAILS" -gt 0 ]]; then
  printf '%s✗ %d failure(s), %d warning(s)%s' "$C_FAIL" "$FAILS" "$WARNS" "$C_OFF"
  [[ "$FIXES" -gt 0 ]] && printf ' — %d fix(es) applied, re-run to confirm' "$FIXES"
  printf '\n'
  exit 2
elif [[ "$WARNS" -gt 0 ]]; then
  printf '%s! %d warning(s), no failures%s\n' "$C_WARN" "$WARNS" "$C_OFF"
  exit 1
else
  printf '%s✓ all checks passed%s\n' "$C_OK" "$C_OFF"
  exit 0
fi
