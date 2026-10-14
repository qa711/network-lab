# Side Phase — Lab-Wide Flow Visibility

Goal: turn the single working exporter (CORP-PBR-A) into whole-estate visibility in Akvorado — both PBRs, Q-EDGE, and the two firewalls, with the NX-OS and IOS-XR boxes as honest stretch goals. By the end, the console's **Exporter** dimension becomes a map of your lab.

**Time budget:** Parts A+B one evening, Part C one evening, D is minutes, E when curious.

---

## Design principles (read once, they explain every choice below)

**1. Input monitors on every routed interface of an instrumented device.** That gives each device a *complete* view — every packet transiting it is seen exactly once on entry. No output monitors needed.

**2. Cross-exporter duplication is inherent — don't fight it.** A single A→B flow will be observed by PBR-A *and* PBR-B (and Q-EDGE if it transits Site Q). Akvorado does not deduplicate across exporters; that's by design — each exporter is an independent observation point. In the console, filter or group by **Exporter** when you want truth; understand that "all exporters" sums *observations*, not unique bytes.

**3. Every new exporter must pass Akvorado's two gates** (both verified in the 2.4.0 source):
- **SNMP metadata:** the outlet polls the *flow packets' source address* with the credentials in outlet.yaml (`REMOVED` under `::/0`). If the poll fails, flows are dropped with `flows_errors_total{error="metadata missing"}`. So every exporter must answer SNMP on the address it sources flows from — for the routers that's already true (LibreNMS polls them); for the firewalls it's a setup step.
- **Sampling rate:** already insured — `default-sampling-rate: 1` under `::/0` covers every unsampled exporter you add. sFlow and IOS-XR advertise their own rates, which override nothing (they simply arrive non-zero).

**4. The flow record must carry interface indexes.** Flows without ifIndex are dropped (`input and output interfaces missing`). Your FNF-RECORD has `match interface input` — keep it in every copy.

---

## Part A — complete the CSRs

### A.1 CORP-PBR-A — extend to all routed interfaces

The record/exporter/monitor already exist; just widen the application:

```
interface GigabitEthernet2
 ip flow monitor FNF-MONITOR input
interface GigabitEthernet3
 ip flow monitor FNF-MONITOR input
interface Tunnel0
 ip flow monitor FNF-MONITOR input
```

(Add Tunnel1 too once Phase 1 Task 3 is done.) Tunnel0 input is a fun one: it sees the *decapsulated inner* flows arriving over GRE — including your multicast — where Gi2 only ever sees ESP.

### A.2 CORP-PBR-B — full stack, mirrored

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
 template data timeout 30
!
flow monitor FNF-MONITOR
 record FNF-RECORD
 exporter FNF-EXPORTER
 cache timeout active 60
 cache timeout inactive 15
!
interface GigabitEthernet1
 ip flow monitor FNF-MONITOR input
interface GigabitEthernet2
 ip flow monitor FNF-MONITOR input
interface GigabitEthernet3
 ip flow monitor FNF-MONITOR input
interface Tunnel0
 ip flow monitor FNF-MONITOR input
```

Loopback99 here is 10.99.250.251 — Akvorado will SNMP-poll that address, which LibreNMS already proves works. Note `template data timeout 30` is baked in from the start this time; you've earned that line.

**Verify:** run some inter-site traffic, then on the box:
```bash
curl -s http://127.0.0.1:8081/api/v0/outlet/metrics | grep netflow_packets_total
```
A second `exporter="::ffff:10.99.250.251"` series appearing = PBR-B is in.

---

## Part B — Q-EDGE (IOS)

Same FNF stack; the only differences are the interfaces and the export path (Q-EDGE reaches the NMS via VRF DMZ):

```
flow record FNF-RECORD
 match ipv4 source address
 match ipv4 destination address
 match transport source-port
 match transport destination-port
 match ip protocol
 match interface input
 collect counter bytes long
 collect counter packets long
 collect timestamp sys-uptime first
 collect timestamp sys-uptime last
!
flow exporter FNF-EXPORTER
 destination 10.99.0.12 vrf DMZ
 source GigabitEthernet0/2.99
 transport udp 2055
 export-protocol netflow-v9
 template data timeout 30
!
flow monitor FNF-MONITOR
 record FNF-RECORD
 exporter FNF-EXPORTER
 cache timeout active 60
 cache timeout inactive 15
!
interface GigabitEthernet0/1
 ip flow monitor FNF-MONITOR input
interface GigabitEthernet0/3.98
 ip flow monitor FNF-MONITOR input
```

(Optionally add Gi0/0 and Gi0/4 for the DMZ side — then you get the pleasingly recursive sight of the SNMP polling and NetFlow export traffic showing up as flows.)

Two Q-EDGE-specific notes:
- **Source address = metadata gate.** Flows source from Gi0/2.99 (10.99.2.1). If Q-EDGE's flows later drop with `metadata missing`, it means Akvorado's SNMP poll to 10.99.2.1 failed — switch the exporter `source` to whichever address LibreNMS polls Q-EDGE on, and it will pass.
- **IOL caveat:** FNF on IOL is software-only and usually exports fine, but some builds are flaky. If `show flow exporter FNF-EXPORTER statistics` shows packets sent but nothing reaches tcpdump on the collector, that's the image, not your config — the cache still proves classification, and the exam doesn't care which box exported.

---

## Part C — the firewalls (multi-vendor flavour)

This is the part that makes the estate feel real — and both devices must pass **both gates**: flow export *and* SNMP with `REMOVED` answering on the address they source flows from. Menu paths below drift slightly between versions; the verification loop at the end of this part is the ground truth.

### C.1 Palo Alto (PA-VM)

1. **NetFlow profile:** Device → Server Profiles → NetFlow → Add. Name `AKVORADO`, template refresh 30 sec / 20 packets, collector `10.99.0.12` port `2055`. Leave "PAN-OS Field Types" unticked — enterprise fields just add noise to a standard decoder.
2. **Attach to interfaces:** Network → Interfaces → each dataplane ethernet you want observed → NetFlow Profile: `AKVORADO`. Commit.
3. **Export path:** PAN-OS sends NetFlow via its *service route*, which defaults to the MGT interface — confirm MGT can reach 10.99.0.12, or repoint it under Device → Setup → Services → Service Route Configuration → Netflow.
4. **SNMP (the metadata gate):** Device → Setup → Operations → SNMP Setup → v2c, community `REMOVED`. Ensure the interface serving SNMP permits it (MGT does by default).

### C.2 OPNsense

1. **Export:** Reporting → NetFlow. Listening interfaces: LAN + WAN (whatever you want observed), version **v9**, Destinations: `10.99.0.12:2055`. Apply.
2. **SNMP (the metadata gate):** System → Firmware → Plugins → install `os-net-snmp`; then Services → Net-SNMP → community `REMOVED`, enable.

### C.3 Verify each firewall the same way

```bash
sudo tcpdump -ni ens4 udp port 2055 and host <firewall-flow-source-ip> -c 3
curl -s http://127.0.0.1:8081/api/v0/outlet/metrics | grep -E 'netflow_packets_total|flows_errors_total'
```

Reading the errors counter is the whole diagnostic: `metadata missing` climbing for that exporter = fix SNMP / source address; `sampling rate missing` = shouldn't happen (the `::/0` default covers it) but would mean the default got lost from outlet.yaml; nothing climbing at all = the export never left (service route / listening interface).

---

## Part D — Akvorado touch-ups and the payoff

**1. Name the remaining prefixes** — add to `clickhouse: networks:` in `~/akvorado/config/akvorado.yaml`:
```yaml
    192.168.0.0/16:
      name: lab-p2p
      role: transit
    172.16.0.0/12:
      name: gre-tunnels
      role: transit
```
Apply: `docker compose restart akvorado-orchestrator akvorado-outlet akvorado-console`

**2. The verification cheat sheet** (works for every part above):
```bash
# who is exporting, and how much has landed:
docker compose exec clickhouse clickhouse-client -q \
  "SELECT ExporterName, ExporterAddress, count(*) AS flows FROM flows GROUP BY ExporterName, ExporterAddress"

# who is being dropped, and why:
curl -s http://127.0.0.1:8081/api/v0/outlet/metrics | grep flows_errors_total | grep -v '^#'
```

**3. In the console:** Visualize → set the dimension to **Exporter** → your whole estate in one sankey. Then dimension **SrcNetName/DstNetName** and watch gret-a-vlan20 talk to belv-b-vlan20 by name. That view — per-site, per-network, per-exporter — is exactly what an MSP NOC dashboard looks like, running on flow data you built end to end.

---

## Part E — stretch goals (expectations set honestly)

### E.1 NX-OS sFlow on CSW1 — an experiment, not a promise
Real Nexus 9000s do sFlow well; the **9000v's virtual data plane may accept this config and sample nothing** — and discovering that is the lesson (same family as your TCAM/PBR finding). Akvorado's inlet already listens on 6343, and sFlow advertises its own sampling rate, so no collector changes needed:
```
feature sflow
sflow agent-ip <CSW1 DMZ-reachable IP>
sflow collector-ip 10.99.0.12 vrf DMZ
sflow sampling-rate 128
sflow data-source interface ethernet 1/5
sflow data-source interface ethernet 1/6
```
Verify with `show sflow statistics` on the switch and tcpdump `udp port 6343` on the collector. Datagrams = delightful surprise; zero = write "sFlow unsupported on 9000v data plane" in your notes and move on.

### E.2 IOS-XR on the CEs — the sampling lesson, completed
XR *requires* a sampler-map — and advertises the rate via v9 **options sampler-table**, which Akvorado's decoder reads natively. So where IOS-XE forced you to configure a default on the collector, XR does it properly on the wire. Worth doing just to see both halves:
```
sampler-map SM-ALL
 random 1 out-of 1
!
flow exporter-map FEM-AKVORADO
 version v9
  options interface-table timeout 60
  options sampler-table timeout 60
  template data timeout 30
 !
 transport udp 2055
 source <interface that reaches 10.99.0.12>
 destination 10.99.0.12
!
flow monitor-map FMM-ALL
 record ipv4
 exporter FEM-AKVORADO
 cache timeout active 60
 cache timeout inactive 15
!
interface GigabitEthernet0/0/0/0
 flow ipv4 monitor FMM-ALL sampler SM-ALL ingress
```
Commit, then check `show flow exporter-map FEM-AKVORADO` and the collector. Caveats: pick the source/destination path off `show route 10.99.0.12` (add `vrf <name>` on the destination line if the CE's management path is VRF'd), and XRv's software forwarding may or may not actually emit — treat like E.1.

### E.3 vEdge cflowd — parked deliberately
SD-WAN flow export needs a centralised policy pushed from vSmart — a proper exercise in its own right, and conveniently v1.2-relevant. Save it for an SD-WAN policy session rather than bolting it on here.

---

## Rollback

Per router: `no ip flow monitor FNF-MONITOR input` on each interface, then `no flow monitor / exporter / record` (PBR-A: keep, it's your Phase 3 build). PA: remove the NetFlow profile from interfaces, commit. OPNsense: clear the destination. sFlow: `no feature sflow`. XR: `no flow ipv4 monitor …` per interface, then remove the maps, commit.

## What this adds to the story

One collector, five-plus exporters, three operating systems and two firewall vendors, with per-site named networks — plus you can now explain sampled vs unsampled export, v9 templates, options tables, and exactly which two gates a collector applies before trusting a flow, because you hit every one of them and read the counters that proved it.
