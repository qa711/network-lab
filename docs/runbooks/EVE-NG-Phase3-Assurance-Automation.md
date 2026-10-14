# Phase 3 — Assurance & Automation: QoS, NetFlow, RESTCONF, AAA, CoPP

Five checklist lines, mostly on the PBR-A / LibreNMS pair plus Q-EDGE and one canary switch. Grounded in your current export: PBR-A already runs `ip http secure-server` + `ip http authentication local`, Gi4 is unused (our safe API-write target), Q-SW39 has no `aaa new-model` yet, and LibreNMS's existing SNMP polling will exercise the CoPP counters for free.

**Time budget:** A+B one evening (they share test traffic), C one evening, D+E one evening.

**One hygiene observation before starting:** the fleet runs `username admin privilege 15 password 0 REMOVED` — plaintext type-0. Parts C and D introduce properly-secured accounts; a fleet-wide `secret` conversion is worth a later pass, but don't change the admin password mid-phase (Oxidized and your own SSH ride on it).

---

# Part A — QoS: the full classify → mark → queue → shape chain

The guide's policy, but with the piece most labs skip: an **ingress marking policy**, so the egress queuing has something real to act on, and a **parent shaper** to manufacture congestion — without congestion, LLQ and bandwidth guarantees are dormant and the counters prove nothing.

Traffic simulation: ICMP plays "voice" (marked EF), SSH plays "business" (marked AF31).

### A.1 Ingress marking — CORP-PBR-A

```
ip access-list extended QOS-VOICE-SIM
 permit icmp any any
ip access-list extended QOS-BUSINESS-SIM
 permit tcp any any eq 22
 permit tcp any eq 22 any
!
class-map match-any MARK-VOICE
 match access-group name QOS-VOICE-SIM
class-map match-any MARK-BUSINESS
 match access-group name QOS-BUSINESS-SIM
!
policy-map MARK-IN
 class MARK-VOICE
  set dscp ef
 class MARK-BUSINESS
  set dscp af31
!
interface GigabitEthernet1
 service-policy input MARK-IN
```

### A.2 Egress queuing under a shaper — CORP-PBR-A

Both Gi2 and Gi3 get it, because your PBR splits VLAN20 traffic to CSW1 and VLAN40 to CSW2:

```
class-map match-any VOICE
 match dscp ef
class-map match-any BUSINESS
 match dscp af31
!
policy-map WAN-OUT
 class VOICE
  priority percent 20
 class BUSINESS
  bandwidth percent 30
 class class-default
  fair-queue
!
policy-map WAN-SHAPE
 class class-default
  shape average 1000000
  service-policy WAN-OUT
!
interface GigabitEthernet2
 service-policy output WAN-SHAPE
interface GigabitEthernet3
 service-policy output WAN-SHAPE
```

The parent shapes everything to 1 Mbps; the child divides that 1 Mbps. So `priority percent 20` = a **200 kbps LLQ policer** — small enough to hit with pings.

**Heads-up:** while WAN-SHAPE is applied, *all* inter-site CORP traffic (tunnels included) is capped at 1 Mbps. Management via the DMZ path (Gi1.99) is unaffected. Remove the shaper when done.

### A.3 Drive traffic and read the counters

```
! NEXUS-A — "voice" flood (EF):
ping 10.2.1.1 vrf CISCO-CORP source 10.2.0.1 count 500 packet-size 1400

! NEXUS-A — "business" (AF31): the TCP handshake is the traffic; login not required
ssh admin@10.1.1.1 vrf CISCO-CORP
```

```
! CORP-PBR-A
show policy-map interface GigabitEthernet1 input     ! MARK-VOICE / MARK-BUSINESS packet counts
show policy-map interface GigabitEthernet2 output    ! parent shaper stats + child classes
```

**What to look for on the egress side:** the parent class shows target/average rate 1000000 and — during the flood — a non-zero queue depth. Under the child, VOICE shows offered packets *and drops*: 1400-byte pings at speed exceed 200 kbps, and the LLQ policer discards the excess. That's the guide's line "strict priority capped to prevent starvation" as a live counter — priority traffic gets absolute preference *up to its cap*, then drops rather than starving BUSINESS and class-default.

### A.4 Break — remove the trust

```
interface GigabitEthernet1
 no service-policy input MARK-IN
```

Re-run the flood: VOICE class counters on Gi2 freeze; everything lands in class-default. Downstream queuing is only as good as upstream marking — that's the trust-boundary concept in one move. Re-apply MARK-IN.

### A.5 Steady state

Remove the shaper after the exercise (`no service-policy output WAN-SHAPE` on Gi2/Gi3). Keep or remove the class-maps/policies as you like — reading them back is Week-3 revision material. Leave **MARK-IN applied** if you're doing Part B next; NetFlow will report the DSCP values it sets.

---

# Part B — Flexible NetFlow → your existing Akvorado

You already run a collector: Akvorado's inlet listens on UDP 2055 by default (confirm the port mapping in its docker-compose on the LibreNMS box). Export goes out the DMZ management path — same route SNMP already proves works.

### B.1 Configure — CORP-PBR-A

```
flow record FNF-RECORD
 match ipv4 source address
 match ipv4 destination address
 match transport source-port
 match transport destination-port
 match ip protocol
 match interface input
 collect ipv4 dscp
 collect counter bytes long
 collect counter packets long
 collect timestamp sys-uptime first
 collect timestamp sys-uptime last
!
flow exporter FNF-EXPORTER
 destination 10.99.0.12 vrf DMZ
 source Loopback99
 transport udp 2055
 export-protocol netflow-v9
!
flow monitor FNF-MONITOR
 record FNF-RECORD
 exporter FNF-EXPORTER
 cache timeout active 60
 cache timeout inactive 15
!
interface GigabitEthernet1
 ip flow monitor FNF-MONITOR input
```

(`collect ipv4 dscp` is the Part A tie-in — flows arrive pre-marking on Gi1 input, so you'll see the original DSCP; move the monitor to Gi2 output later if you want to see EF/AF31 post-marking. If your release rejects the `vrf DMZ` keyword on the destination, drop the exporter lines and run cache-only — the checklist line is still fully covered.)

### B.2 Generate and verify

Re-run the Part A traffic, then:

```
show flow monitor FNF-MONITOR cache format table   ! flows: src/dst, ports, proto, counters
show flow exporter FNF-EXPORTER statistics         ! export packets sent, no errors
show running-config | section flow                 ! the guide's own verification
```

**Expected in the cache:** your ICMP flood as proto 1 flows, the SSH attempt as proto 6 dst-port 22, byte/packet counters climbing. On the collector side, check Akvorado's UI for a new exporter at 10.99.250.250; fallback if Akvorado isn't listening:

```
# LibreNMS box
sudo apt install nfdump
sudo nfcapd -D -p 2055 -l /tmp/nfcap        # only if 2055 is free
nfdump -R /tmp/nfcap -o extended | head
```

Flow accounting vs packet capture, the exam distinction: the cache shows *who talked to whom, how much* — never payload.

---

# Part C — RESTCONF and NETCONF on IOS-XE

PBR-A is one command from RESTCONF-ready. Create a dedicated API account rather than reusing admin:

### C.1 Enable — CORP-PBR-A

```
username api privilege 15 secret REMOVED
restconf
netconf-yang
```

Optional hygiene while here: `no ip http server` (plain HTTP is on fleet-wide; RESTCONF only needs the secure server).

```
show netconf-yang status                  ! netconf-yang: enabled, ssh port 830
show ip http server secure status
```

### C.2 Read via RESTCONF — from the LibreNMS box

Target the DMZ management loopback (10.99.250.250) — the path your NMS already uses:

```
curl -k -u api:REMOVED -H "Accept: application/yang-data+json" \
  https://10.99.250.250/restconf/data/ietf-interfaces:interfaces

curl -k -u api:REMOVED -H "Accept: application/yang-data+json" \
  https://10.99.250.250/restconf/data/ietf-interfaces:interfaces/interface=GigabitEthernet1
```

**Expected:** JSON — name, description, type, enabled — for every interface. Put it next to `show ip interface brief` on the router (the guide's task): same truth, machine-readable.

### C.3 Write via RESTCONF — the part that makes it click

Gi4 is unused, so it's a safe target:

```
curl -k -u api:REMOVED -X PATCH -H "Content-Type: application/yang-data+json" \
  https://10.99.250.250/restconf/data/ietf-interfaces:interfaces/interface=GigabitEthernet4 \
  -d '{"ietf-interfaces:interface":{"name":"GigabitEthernet4","description":"SET-BY-RESTCONF"}}'
```

Expect `204 No Content` (silent success), then on the router: `show running-config interface GigabitEthernet4` — the description is there. You've configured IOS-XE without touching the CLI. Clean up by PATCHing a new description or `no description` conventionally.

### C.4 NETCONF — see the other protocol's shape

```
# LibreNMS box
ssh -p 830 api@10.99.250.250 -s netconf
```

**Expected:** a wall of XML — the `<hello>` with capability list. That contrast *is* the exam table: RESTCONF = HTTPS/JSON/REST-style, NETCONF = SSH-830/XML/RPC, same YANG models underneath. Ctrl-C out. If the port times out on the DMZ path while RESTCONF works, you've met a real IOS-XE quirk — NETCONF listening only in the global VRF on some releases. Note it and move on; RESTCONF covers the configure-and-verify line.

### C.5 Breaks (two minutes)

Wrong password → HTTP 401. `no restconf` → connection refused, `restconf` to restore. The REST-API-security checklist line maps here: HTTPS transport, least-privilege accounts, no `-k` in production (validate certs), no hard-coded secrets.

---

# Part D — AAA: TACACS+ device administration

Server is `tac_plus` on the LibreNMS Ubuntu (10.99.0.12). Canary device is Q-SW39 — its mgmt SVI reaches 10.99.0.12 over the same DMZ path SNMP already uses. If your ISE VM boots, everything below is identical except the server address and key.

**Safety rule for this part: keep a working SSH session AND the console open on Q-SW39 until the break test passes.** Console authentication is untouched throughout.

### D.1 Server — LibreNMS box

```
sudo apt update && sudo apt install tacacs+
sudo nano /etc/tacacs+/tac_plus.conf
```

Minimal config (replace the file's example content):

```
key = REMOVED

user = quser {
    login = cleartext REMOVED
    service = exec {
        priv-lvl = 15
    }
}
```

```
sudo systemctl restart tacacs_plus
sudo systemctl status tacacs_plus
ss -ltn | grep :49          ! listening on tcp/49
```

### D.2 Canary — Q-SW39

Order matters: pin the local safety net *before* anything else.

```
aaa new-model
aaa authentication login default local
!
tacacs server LNMS-TAC
 address ipv4 10.99.0.12
 key REMOVED
!
aaa group server tacacs+ TAC-GROUP
 server name LNMS-TAC
!
aaa authentication login VTY-AUTH group TAC-GROUP local
aaa authorization exec VTY-AUTHZ group TAC-GROUP local
aaa accounting exec VTY-ACCT start-stop group TAC-GROUP
!
ip tacacs source-interface Vlan99
!
line vty 0 4
 login authentication VTY-AUTH
 authorization exec VTY-AUTHZ
 accounting exec VTY-ACCT
```

(Named method lists on the vty only — console and default stay local. That's the lockout-proof pattern. Adjust the source-interface if your mgmt SVI is named differently.)

### D.3 Verify

```
test aaa group TAC-GROUP quser REMOVED legacy    ! "User successfully authenticated"
show tacacs                                          ! socket opens, request/response counters
```

Fresh SSH to Q-SW39 as **quser** → straight to `#` (priv 15 from the server's exec authorization — no enable password needed: that's authorization doing its job, distinct from authentication). On the server, watch accounting arrive:

```
sudo tail -f /var/log/tac_plus.acct     # or: sudo journalctl -u tacacs_plus -f
```

Start/stop records with username, line, and source — the third A, live.

### D.4 The break that earns your trust — fallback proof

Before rolling TACACS to more devices, prove the `local` at the end of the method lists actually catches you:

```
# LibreNMS box
sudo systemctl stop tacacs_plus
```

New SSH to Q-SW39: `quser` now **fails** (server dead, no local quser), but `admin` **succeeds** after a short server-timeout pause — the method list walked `group TAC-GROUP` → dead → `local` → matched. That pause-then-local-login signature is what a TACACS outage looks like in production. `sudo systemctl start tacacs_plus`, confirm quser works again.

Once trusted, replicating to the fleet is a paste of D.2 per device.

---

# Part E — CoPP: build one, inspect one

### E.1 Build — Q-EDGE (IOS)

Q-EDGE's control plane now sees OSPF (two VRFs), PIM and IGMP (your Site Q multicast extension), SSH, SNMP from LibreNMS, and ICMP. Three classes: routing protected absolutely, management policed, everything else measured:

```
ip access-list extended COPP-MGMT
 permit tcp 10.99.0.0 0.0.255.255 any eq 22
 permit udp 10.99.0.0 0.0.255.255 any eq 161
 permit icmp 10.99.0.0 0.0.255.255 any
ip access-list extended COPP-ROUTING
 permit ospf any any
 permit pim any any
 permit igmp any any
!
class-map match-any COPP-ROUTING-CLASS
 match access-group name COPP-ROUTING
class-map match-any COPP-MGMT-CLASS
 match access-group name COPP-MGMT
!
policy-map COPP-POLICY
 class COPP-ROUTING-CLASS
 class COPP-MGMT-CLASS
  police 64000 conform-action transmit exceed-action drop
 class class-default
  police 256000 conform-action transmit exceed-action transmit
!
control-plane
 service-policy input COPP-POLICY
```

Design notes worth internalising: the ROUTING class carries **no police statement** — classify-and-transmit, because a mis-sized policer here drops hellos and takes down adjacencies (the guide's production warning, engineered out). class-default polices with *transmit/transmit* — monitor mode: counts what would exceed, drops nothing, exactly how you'd stage CoPP in production before enforcing.

### E.2 Verify

```
show policy-map control-plane
```

**Expected within a minute, no effort:** COPP-MGMT-CLASS conform counters climbing (LibreNMS SNMP polls), COPP-ROUTING-CLASS counting OSPF/PIM hellos steadily. SSH in from the NMS box and watch your own session tick the counter.

### E.3 Break — feel the policer

```
policy-map COPP-POLICY
 class COPP-MGMT-CLASS
  police 8000 conform-action transmit exceed-action drop
```

From the LibreNMS box: `ping 10.99.2.1 -i 0.01 -s 1000` (fast, big). **Expected:** heavy loss on the ping, `exceeded ... drop` counters climbing in `show policy-map control-plane` — and note your SSH session getting sluggish, because it shares the class. CoPP protects the CPU from management traffic *including yours* — the double edge the guide warns about. Restore `police 64000`.

Recovery note: if you ever wedge management entirely, the EVE-NG console is unaffected — `control-plane` → `no service-policy input COPP-POLICY`.

### E.4 Inspect — the N9Kv contrast

NX-OS refuses to run without CoPP; it shipped attached before you configured anything:

```
! CSW1
show copp status                                        ! copp-system-p-policy-strict attached
show policy-map interface control-plane | i class-map|violate
```

Scroll the class list — management, IGMP, routing protocols, ARP, all pre-classified with per-class policers, and `violated` counters showing anything already being dropped. IOS makes you build CoPP; NX-OS makes you *tune* it — a tidy exam contrast, and the reason a default N9K survives abuse a default ISR wouldn't.

---

## Rollback

**A:** `no service-policy` (input Gi1, output Gi2/Gi3), then `no policy-map MARK-IN / WAN-OUT / WAN-SHAPE`, `no class-map ...`, `no ip access-list extended QOS-*`.
**B:** `no ip flow monitor FNF-MONITOR input` on Gi1, then `no flow monitor / exporter / record`.
**C:** `no restconf`, `no netconf-yang`, `no username api`.
**D:** on Q-SW39 remove the three list applications under vty, then the lists, group, server, and (last) `no aaa new-model`; `sudo apt remove tacacs+` on the box.
**E:** `control-plane` → `no service-policy input COPP-POLICY`, then remove policy/classes/ACLs. (Don't touch the N9Kv's system policy.)

## Checklist mapping

| ENCOR line | Where |
|---|---|
| QoS config interpretation | Part A (marking, LLQ cap drops, shaping vs policing, trust boundary) |
| Flexible NetFlow | Part B (record/exporter/monitor, cache + collector, DSCP visibility) |
| NETCONF and RESTCONF | Part C (read, write via PATCH, both protocol shapes) |
| REST API security | C.5 (transport, least privilege, cert validation, secrets) |
| AAA authentication & authorisation | Part D (named lists, priv-15 authz, accounting, fallback proven) |
| ACLs / CoPP | Part E (build + break on IOS, inspect defaults on NX-OS) |
