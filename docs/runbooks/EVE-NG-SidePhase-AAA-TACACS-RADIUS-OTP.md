# Side Phase — TACACS+, RADIUS and Authenticator-App OTP

Three engines, each doing the job it's actually good at:

| Engine | Where | Job |
|---|---|---|
| **tac_plus** (built from source) | Ubuntu 10.99.0.12 | Simple TACACS+ — the protocol, bare. Your fallback and reference. |
| **FreeRADIUS + Google Authenticator PAM** | Ubuntu 10.99.0.12 | The **OTP engine**. This is what your phone talks to. |
| **Cisco ISE** | Gret A, mgmt segment | The **policy engine** — per-command authorization, and a front-end that can proxy to the OTP engine. |

**The headline flow you're building:**

```
You ──SSH──► Q-SW39 ──TACACS+──► ISE ──proxy──► FreeRADIUS ──PAM──► Google Authenticator (TOTP)
                                   │
                                   └──► shell profile (priv 15) + command set (what you may type)
```

Login with a 6-digit code from your phone **and** get per-command authorization. That's genuinely enterprise-grade, and it's four parts away.

**Time budget:** Part 0 = 10 min. Part A+B = one evening (this is the OTP payoff). Part C = one evening. Part D = one evening. Parts E/F when curious.

---

## Two facts to internalise before touching anything

**1. TOTP only works over PAP.** The OTP is validated by PAM, which needs the plaintext token. VTY login over RADIUS sends PAP — fine. **EAP-based 802.1X cannot do TOTP this way** (EAP methods derive keys from a stored credential; there's nothing for PAM to check). So: OTP for *device admin login*, certificates/PEAP for *network access*. That's not a lab limitation, that's how the protocols work — and it's a great exam-level distinction.

**2. Method lists fall through on NO RESPONSE, not on REJECT.** `aaa authentication login VTY-AUTH group RAD-GROUP local` tries RADIUS; if RADIUS says *reject*, that's authoritative and you're **done** — it does not try `local`. Only a dead/unreachable server advances to the next method. This is why you never mix two live auth servers in one list hoping for "try both".

**Safety rule for the entire phase:** keep a console session open on Q-SW39 at all times. By default IOS exempts the console from `aaa authorization`, so the console is your escape hatch even if you break command authorization completely. Never remove `local` from the end of a method list.

---

## Part 0 — finish tac_plus (10 minutes)

Your daemon builds and starts, then systemd kills it: tac_plus forks to background, systemd sees the parent exit, sends SIGTERM to the child. Keep it in the foreground.

```bash
sudo systemctl stop tac_plus
sudo sed -i 's|tac_plus -C|tac_plus -G -C|' /etc/systemd/system/tac_plus.service
sudo systemctl daemon-reload
sudo systemctl start tac_plus
sudo systemctl status tac_plus        # want: active (running), NOT "inactive (dead)"
ss -ltnp | grep :49
```

> If `tac_plus -G` errors with an illegal option, your build doesn't have the foreground flag — use `Type=forking` instead: add `Type=forking` under `[Service]`, leave ExecStart without `-G`, `daemon-reload`, restart.

Validate the config file any time with: `tac_plus -P -C /etc/tacacs+/tac_plus.conf`

**Firewall** — the box now needs three ports open. Check and allow:
```bash
sudo ufw status
# if active:
sudo ufw allow 49/tcp comment 'TACACS+'
sudo ufw allow 1812/udp comment 'RADIUS auth'
sudo ufw allow 1813/udp comment 'RADIUS acct'
```

**Then re-test from Q-SW39:**
```
ping 10.99.0.12 source vlan99
test aaa group TAC-GROUP quser REMOVED legacy      ! want: User successfully authenticated
show tacacs                                            ! socket opens / requests / responses
```

If the ping works but the test still fails, check `show run | inc tacacs` — key must be exactly `REMOVED`, and `ip tacacs source-interface Vlan99` must be set so the switch sources from an address the server can reply to.

---

## Part A — FreeRADIUS + Google Authenticator (the OTP engine)

### A.1 Time sync — do this first, not last

TOTP is a function of the clock. **Skew is the number-one cause of "wrong code" failures**, and it fails in a way that looks like a config error.

```bash
timedatectl                      # want: "System clock synchronized: yes"
sudo timedatectl set-ntp true
```

Your phone must also be on network time (Settings → Date & Time → Automatic). A window of ±90s is what we'll configure, which is forgiving but not infinite.

### A.2 Install

```bash
sudo apt update
sudo apt install freeradius freeradius-utils libpam-google-authenticator
```

(FreeRADIUS on Ubuntu 24.04 is 3.2.x, but the config directory is still called `3.0` — that's normal, not a mistake.)

### A.3 Create the OTP user and enrol your phone

The FreeRADIUS daemon runs as user `freerad`, so the secret must live somewhere `freerad` can read. Central directory, not a home dir:

```bash
sudo mkdir -p /etc/freeradius/3.0/googleauth
sudo chmod 700 /etc/freeradius/3.0/googleauth

sudo google-authenticator -t -d -f -r 3 -R 30 -w 3 -e 5 \
     -s /etc/freeradius/3.0/googleauth/netadmin
```

Flags: `-t` time-based, `-d` disallow code reuse, `-f` write without prompting, `-r 3 -R 30` rate-limit 3 attempts per 30s, `-w 3` allow ±1 window (~90s skew), `-e 5` emergency scratch codes.

**A QR code prints in the terminal.** Scan it with Google Authenticator / Authy / Microsoft Authenticator / 1Password — any TOTP app. **Copy the emergency scratch codes somewhere safe** — they're single-use logins if you lose the phone.

Now hand the file to the daemon:

```bash
sudo chown -R freerad:freerad /etc/freeradius/3.0/googleauth
sudo chmod 600 /etc/freeradius/3.0/googleauth/netadmin
```

### A.4 Wire PAM

Replace `/etc/pam.d/radiusd` entirely — **OTP-only to start** (you type just the 6 digits as your password). We add the static password in A.7 once the mechanism is proven.

```bash
sudo tee /etc/pam.d/radiusd << 'EOF'
auth       required     pam_google_authenticator.so secret=/etc/freeradius/3.0/googleauth/${USER} allowed_perm=0600
account    required     pam_permit.so
session    required     pam_permit.so
EOF
```

`${USER}` is expanded by the PAM module, so one line serves every user you enrol later.

### A.5 Enable the PAM module in FreeRADIUS

```bash
sudo ln -s /etc/freeradius/3.0/mods-available/pam /etc/freeradius/3.0/mods-enabled/pam
```

Then uncomment `pam` in the `authenticate {}` section of `/etc/freeradius/3.0/sites-available/default`:

```bash
sudo nano /etc/freeradius/3.0/sites-available/default
```
Find the `authenticate {` block and remove the `#` from the line that is just `pam`.

### A.6 User and client

Add the user at the **top** of `/etc/freeradius/3.0/mods-config/files/authorize` (above the `DEFAULT` entries — first match wins):

```
netadmin  Auth-Type := PAM
          Service-Type = NAS-Prompt-User,
          Cisco-AVPair = "shell:priv-lvl=15"
```

`Auth-Type := PAM` sends this user down the PAM stack you just built. The reply attributes are what drop you straight to `#` — RADIUS's equivalent of a TACACS+ shell profile.

Add your lab as a client in `/etc/freeradius/3.0/clients.conf`:

```
client lab-mgmt {
        ipaddr = 10.99.0.0/16
        secret = REMOVED
        nas_type = cisco
        shortname = lab
}
```

(One subnet entry covers every device that sources from the mgmt/DMZ range — adjust the prefix if your devices source elsewhere. Leave the shipped `client localhost` alone; the next step uses it.)

### A.7 Test locally — before any switch is involved

Run FreeRADIUS in the foreground so you can *watch* the auth happen. This is the single most useful FreeRADIUS skill there is:

```bash
sudo systemctl stop freeradius
sudo freeradius -X
```

In a second SSH session, with a fresh code from your phone:

```bash
radtest netadmin 123456 127.0.0.1 0 testing123
```

**Expected:** `Received Access-Accept`, carrying `Service-Type` and `Cisco-AVPair`. In the `-X` window you'll see the PAM module called and `pam_authenticate: Success`. Try again with the *same* code — it should now **fail** (that's `-d`, replay protection, working).

Common `-X` failures and what they mean:
- `PAM: Cannot open ... Permission denied` → the chown/chmod in A.3 didn't take
- `Invalid verification code` → clock skew (recheck `timedatectl`), or you fat-fingered it
- `Auth-Type PAM not found` → the symlink in A.5 or the `pam` line in `sites-available/default`

Once it works: `Ctrl-C`, then `sudo systemctl start freeradius`.

---

## Part B — Canary: OTP login on Q-SW39

### B.1 Switch config

```
radius server LNMS-RAD
 address ipv4 10.99.0.12 auth-port 1812 acct-port 1813
 key REMOVED
!
aaa group server radius RAD-GROUP
 server name LNMS-RAD
!
ip radius source-interface Vlan99
!
aaa authentication login VTY-OTP group RAD-GROUP local
aaa authorization exec VTY-OTP-AUTHZ group RAD-GROUP local
!
line vty 0 4
 login authentication VTY-OTP
 authorization exec VTY-OTP-AUTHZ
```

**Note the explicit ports.** Cisco's historic default is 1645/1646; FreeRADIUS listens on 1812/1813. Omit `auth-port 1812 acct-port 1813` and you get silent timeouts — a classic.

Test without risking your session:
```
test aaa group RAD-GROUP netadmin <6-digit-code> new-code
```

### B.2 The login

SSH to Q-SW39 as `netadmin`. At the password prompt, type the **6-digit code from your phone**. You should land straight at `#` (priv 15, courtesy of the Cisco-AVPair).

Stop and appreciate what just happened: the switch never knew about TOTP. It sent PAP to RADIUS; RADIUS asked PAM; PAM checked the shared secret against the clock. Zero changes to the AAA protocol — this is why token-based auth bolted onto RADIUS so easily in the 90s and still does.

### B.3 Upgrade to real two-factor (password + OTP)

Right now the phone is the *only* factor. True MFA = something you know + something you have. The RADIUS `User-Password` field carries one string, so the convention is **password immediately followed by the code**, with PAM splitting them:

```bash
# Give netadmin a system password to check against:
sudo useradd -M -s /usr/sbin/nologin netadmin 2>/dev/null
sudo passwd netadmin

# freerad must be able to read /etc/shadow to verify it:
sudo usermod -a -G shadow freerad

sudo tee /etc/pam.d/radiusd << 'EOF'
auth       requisite    pam_google_authenticator.so forward_pass secret=/etc/freeradius/3.0/googleauth/${USER} allowed_perm=0600
auth       required     pam_unix.so use_first_pass
account    required     pam_permit.so
session    required     pam_permit.so
EOF

sudo systemctl restart freeradius
```

`forward_pass` tells the OTP module to strip the trailing 6 digits, validate them, and hand the *remainder* to `pam_unix` as the password. So at the switch's password prompt you now type `REMOVED` — password then code, no space.

Test: `radtest netadmin 'REMOVED' 127.0.0.1 0 testing123`

> **Security note, stated honestly:** adding `freerad` to the `shadow` group lets the RADIUS daemon read every password hash on the box. Acceptable in a lab; in production you'd point PAM at a dedicated credential store (LDAP/SSSD) instead. Know the tradeoff you're making — that's the REST-API-security mindset applied to AAA.

### B.4 Breaks

| Break | Do it | Expected |
|---|---|---|
| **Replay** | Log in with a code, immediately log in again with the same code | Rejected — `-d` blocks reuse. This is why TOTP resists shoulder-surfing. |
| **Clock skew** | `sudo timedatectl set-ntp false && sudo date -s "+5 minutes"` | Every code fails. Restore with `set-ntp true`. Now you'll *recognise* this failure instead of debugging config for an hour. |
| **Server down** | `sudo systemctl stop freeradius` | `netadmin` fails; **`admin` still works via `local`** after a timeout pause. The fallback is real. Restart after. |
| **Reject ≠ fallthrough** | With FreeRADIUS *running*, SSH as a username it doesn't know | Rejected outright — IOS does **not** try `local`. This is the fact from the top of the doc, felt. |

---

## Part C — ISE: the policy engine (per-command authorization)

tac_plus authenticates. **ISE decides what you're allowed to type.** That's the TACACS+ superpower RADIUS doesn't have — and it's the exam point.

> ISE GUI paths drift between 3.x releases; treat these as approximate and navigate by name. The verification at C.5 is the ground truth.

### C.1 Enable Device Admin

- **Administration → System → Licensing** — confirm a Device Admin license is present (the eval covers it).
- **Administration → System → Deployment →** your node **→ Edit →** tick **Enable Device Admin Service** → Save. (ISE will restart services — this takes a while. Go make tea.)

### C.2 Add Q-SW39 as a network device

**Administration → Network Resources → Network Devices → Add**
- Name `Q-SW39`, IP = Q-SW39's Vlan99 address
- Tick **TACACS+ Authentication Settings** → Shared Secret: `REMOVED`

### C.3 Two users, two roles

**Administration → Identity Management → Identities → Users → Add** — create:
- `netops-admin` (put it in a group, e.g. `Network Admins`)
- `netops-ro` (group e.g. `Network Read Only`)

### C.4 The results objects

**Work Centers → Device Administration → Policy Elements → Results:**

- **TACACS Profiles → Add:** `Shell-Priv15` — Common Task Type = **Shell**, Default Privilege **15**, Maximum Privilege **15**.
- **TACACS Profiles → Add:** `Shell-Priv1` — Default Privilege **1**, Maximum **1**.
- **TACACS Command Sets → Add:** `CMD-ReadOnly` — leave **"Permit any command that is not listed below" unticked**, then permit only:
  - `show` (arguments: `.*`)
  - `ping` (arguments: `.*`)
  - `exit`
- **TACACS Command Sets → Add:** `CMD-Full` — tick **"Permit any command that is not listed below"**.

### C.5 The policy set

**Work Centers → Device Administration → Device Admin Policy Sets → Add**
- Name `Lab-DeviceAdmin`, condition: Device Type / Network Device Name matches your lab (or just `Any` for now)
- **Authentication Policy:** Identity Source = **Internal Users**
- **Authorization Policy** — two rules:
  - `netops-admin` in *Network Admins* → Shell Profile `Shell-Priv15` + Command Set `CMD-Full`
  - `netops-ro` in *Network Read Only* → Shell Profile `Shell-Priv1` + Command Set `CMD-ReadOnly`

### C.6 Point Q-SW39 at ISE — with command authorization

```
tacacs server ISE-TAC
 address ipv4 <ISE-IP>
 key REMOVED
!
aaa group server tacacs+ ISE-GROUP
 server name ISE-TAC
!
aaa authentication login VTY-ISE group ISE-GROUP local
aaa authorization exec VTY-ISE-AUTHZ group ISE-GROUP local
aaa authorization commands 15 CMD-AUTHZ group ISE-GROUP local
aaa authorization commands 1 CMD-AUTHZ1 group ISE-GROUP local
aaa accounting commands 15 CMD-ACCT start-stop group ISE-GROUP
!
line vty 0 4
 login authentication VTY-ISE
 authorization exec VTY-ISE-AUTHZ
 authorization commands 15 CMD-AUTHZ
 authorization commands 1 CMD-AUTHZ1
 accounting commands 15 CMD-ACCT
```

**This is the one that can bite.** Command authorization means *every command you type is a TACACS+ round trip*. If ISE misbehaves, your VTY session becomes read-only or worse. Console is exempt (no `aaa authorization console` configured) — that's your way back in. `local` on the end means an ISE outage degrades to local authorization rather than a lockout.

### C.7 The demo — this is the moment

Two SSH sessions:

```
! as netops-admin
Q-SW39# conf t                         ← works
```

```
! as netops-ro
Q-SW39> show ip interface brief        ← works
Q-SW39> ping 10.99.0.12                ← works
Q-SW39> conf t
Command authorization failed.          ← ✅ THE POINT
```

Then look at **Operations → TACACS → Live Logs** in ISE: every command, per user, per device, accepted or denied. That is exactly why TACACS+ owns device administration and RADIUS doesn't — RADIUS authorizes the *session*, TACACS+ authorizes *every command*, and it accounts for them individually.

---

## Part D — the crown: OTP *through* ISE, with command authorization

Now join the two halves. ISE can use an external **RADIUS Token Server** as its identity source — that's how enterprises wire RSA SecurID in, and FreeRADIUS-with-TOTP slots into exactly the same socket.

### D.1 FreeRADIUS: trust ISE as a client

Add to `/etc/freeradius/3.0/clients.conf` (if ISE isn't already inside the `10.99.0.0/16` block from A.6, add it explicitly):

```
client ise {
        ipaddr = <ISE-IP>
        secret = REMOVED
        shortname = ise
}
```
```bash
sudo systemctl restart freeradius
```

### D.2 ISE: define the token server

**Administration → Identity Management → External Identity Sources → RADIUS Token → Add**
- Name: `FREERAD-OTP`
- **Connection** tab: Host IP `10.99.0.12`, Shared Secret `REMOVED`, Authentication Port `1812`
- Save, then use the **Test Connection** button if your version offers one.

### D.3 Sequence it, then use it

**Administration → Identity Management → Identity Source Sequences → Add**
- Name `SEQ-OTP`, add `FREERAD-OTP` to the authentication search list.

Then in your `Lab-DeviceAdmin` policy set:
- **Authentication Policy** → change Identity Source from *Internal Users* to **`SEQ-OTP`**
- **Allowed Protocols** must permit **PAP/ASCII** (TACACS+ ASCII login carries the password in the clear to ISE, which is exactly what lets ISE forward it to the token server)
- **Authorization Policy** → the `netadmin` user needs a rule → give it `Shell-Priv15` + `CMD-Full` (or `CMD-ReadOnly` if you want an OTP-protected read-only role — arguably the most realistic combination of all)

### D.4 Verify

SSH to Q-SW39 as `netadmin`, password = `REMOVED` (password + code, per B.3).

**What happens:** switch → TACACS+ → ISE → RADIUS/PAP → FreeRADIUS → PAM → TOTP validated → back up the chain → ISE applies shell profile and command set. You are logged in with a phone code **and** ISE is authorizing every command you type.

Watch it in **Operations → TACACS → Live Logs** — the authentication shows the external identity store in the detail view.

> **If your ISE version won't accept a RADIUS Token source for a *device admin* policy set** (some releases restrict token servers to RADIUS/network-access policy sets), don't fight it: keep OTP on the direct Q-SW39→FreeRADIUS path from Part B, and keep ISE for command authorization. You've still built and understood both halves — and "the product wouldn't do X, so I designed around it" is a better interview story than a clean happy path.

---

## Part E — fleet rollout (the safe pattern)

Never roll AAA to the fleet in one go. Per device:

1. Add the device in ISE (**Network Devices**) with the shared secret.
2. Paste the C.6 block, adjusting `<source-interface>` to that device's mgmt SVI/loopback.
3. **Before logging out**, from your existing session: `test aaa group ISE-GROUP netops-admin <password> new-code`
4. Open a *second* SSH session and log in as `netops-admin`. Only when that works, close the first.
5. `local` stays on every method list, forever. Non-negotiable.

NX-OS differs (`feature tacacs+`, `tacacs-server host … key …`, `aaa authentication login default group ISE-GROUP local`) — worth doing on one Nexus just to meet the syntax, since your estate is multi-OS and the exam is IOS-flavoured.

---

## Part F — stretch: 802.1X (RADIUS network access)

This is where RADIUS earns its keep, and where TOTP explicitly **cannot** follow (see the top of the doc).

On an access port:
```
aaa authentication dot1x default group RAD-GROUP
aaa authorization network default group RAD-GROUP
dot1x system-auth-control
!
interface <access-port>
 authentication port-control auto
 authentication host-mode single-host
 mab
 dot1x pae authenticator
 spanning-tree portfast
```

Honest caveats: you need a **real supplicant** — VPCS can't do 802.1X. Use the Linux node with `wpa_supplicant` (EAP-MD5 is easiest against FreeRADIUS; PEAP needs a server cert). If that's too much yak-shaving, **MAB** (MAC Authentication Bypass) demonstrates the RADIUS network-access flow with no supplicant at all: FreeRADIUS just needs a users-file entry keyed on the MAC. For ENCOR, understanding the flow and the role of the authenticator/supplicant/auth-server triangle matters more than a working supplicant.

---

## Rollback

```
! Q-SW39 — remove applications first, then the objects
line vty 0 4
 no authorization commands 15 CMD-AUTHZ
 no authorization commands 1 CMD-AUTHZ1
 no authorization exec VTY-ISE-AUTHZ
 no login authentication VTY-ISE
 login authentication default
!
no aaa authorization commands 15 CMD-AUTHZ
no aaa authorization commands 1 CMD-AUTHZ1
no aaa authentication login VTY-ISE
no aaa authentication login VTY-OTP
no aaa group server radius RAD-GROUP
no radius server LNMS-RAD
no tacacs server ISE-TAC
```
```bash
# Ubuntu
sudo systemctl disable --now freeradius tac_plus
sudo gpasswd -d freerad shadow          # undo the shadow-group grant
```
ISE: disable the policy set rather than deleting objects — you'll want them again.

---

## Checklist mapping

| ENCOR line | Where |
|---|---|
| AAA authentication | Parts A, B (RADIUS+PAP+TOTP), C (TACACS+ via ISE) |
| AAA authorisation | C.4–C.7 — shell profiles, command sets, per-command authz |
| AAA accounting | C.6 (`aaa accounting commands 15`) + ISE Live Logs |
| TACACS+ vs RADIUS | The whole phase — you build both and feel *why* device admin uses one and network access the other |
| ACLs / CoPP tie-in | The `COPP-MGMT` class in Phase 3 already protects tcp/49 and udp/1812 — now it's protecting something real |
| REST API security (MFA, least privilege) | B.3 security note, C.4 read-only role |
| TrustSec / ISE / endpoint | Parts C–D give you first-hand ISE policy-engine experience — the describe-level topics stop being abstract |
| 802.1X | Part F |

## What this adds to the story

"I built TACACS+ from source, stood up FreeRADIUS with TOTP against Google Authenticator, and fronted both with ISE so that device logins take a phone code *and* every command is authorized per-role — then I proved the local fallback works by killing the servers." That's not a cert lab answer. That's an engineer's answer.
