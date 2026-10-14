# Phase 2 — Multicast Across the CORP VRF

Covers the whole multicast line of your checklist: **PIM-SM, IGMPv2, IGMPv3, SSM, MSDP** (as anycast-RP), plus **BiDir** at describe-level and RPF manipulation with static mroutes. Everything runs on existing devices — no new nodes.

**Time budget:** Parts A–D one evening. Part E ~45 min. Parts F–G another hour.

---

## The multicast domain

```
 SOURCE                                                        RECEIVER
 NEXUS-A Vlan10 (10.1.0.1/24, area 10)          NEXUS-B Vlan10 (10.1.1.1/24, area 10)
        |                                                          |
      E1/8 ──── Gi1  PBR-A  Gi2 ──── E1/5 CSW1 E1/6 ──── Gi2  PBR-B  Gi1 ──── E1/8
                 |  (RP: Lo100)                                |
                 Gi3 ─────── E1/5 CSW2 E1/6 ─────────────────── Gi3
                 |                                             |
                 └──────────── Tunnel0 (172.16.12.0/30) ────────┘   (in OSPF, high cost)
```

All in VRF **CISCO-CORP** on the NX-OS boxes, global table on the PBR CSRs (they're the same OSPF domain).

**Address plan** (verified unused in the lab):

| Item | Value |
|---|---|
| ASM group | 239.1.1.10 |
| SSM group | 232.1.1.1 |
| BiDir group range | 239.200.1.0/24 |
| RP (later anycast) | 10.255.100.1/32 = PBR-A **Loopback100** (Part F adds the same on PBR-B) |
| MSDP peer IDs | PBR-A Lo101 = 10.255.101.1/32, PBR-B Lo101 = 10.255.101.2/32 |

**RPF prediction worth knowing up front:** PBR-B has two equal-cost paths toward site A (via CSW1 next-hop 10.20.30.1, via CSW2 next-hop 10.20.60.1). With ECMP, IOS RPF picks the **highest next-hop IP** → expect the tree to pin through **CSW2**. You'll verify and then break this in Part E.

## Part 0 — prerequisite

Apply the outstanding NEXUS-A fix first, or RPF toward PBR-A's Gi2/Gi3 subnets is ambiguous and this lab will behave randomly:

```
! NEXUS-A
no interface Ethernet1/6.30
no interface Ethernet1/7.30
```

Confirm before continuing: `show ip route 10.10.30.2 vrf CISCO-CORP` on CSW1 shows a single path via E1/5.

---

## Part A — PIM-SM foundation

### CORP-PBR-A (IOS-XE)
```
ip multicast-routing distributed
!
interface Loopback100
 description RP-ANYCAST
 ip address 10.255.100.1 255.255.255.255
 ip pim sparse-mode
!
interface GigabitEthernet1
 ip pim sparse-mode
interface GigabitEthernet2
 ip pim sparse-mode
interface GigabitEthernet3
 ip pim sparse-mode
!
router ospf 1
 network 10.255.100.1 0.0.0.0 area 0
!
ip pim rp-address 10.255.100.1
```

### CORP-PBR-B (IOS-XE)
```
ip multicast-routing distributed
!
interface GigabitEthernet1
 ip pim sparse-mode
interface GigabitEthernet2
 ip pim sparse-mode
interface GigabitEthernet3
 ip pim sparse-mode
!
ip pim rp-address 10.255.100.1
```

### CSW1 and CSW2 (NX-OS — identical block on both)
```
feature pim
!
interface Ethernet1/5
  ip pim sparse-mode
interface Ethernet1/6
  ip pim sparse-mode
!
vrf context CISCO-CORP
  ip pim rp-address 10.255.100.1 group-list 224.0.0.0/4
```

### NEXUS-A (NX-OS)
```
feature pim
!
interface Ethernet1/8
  ip pim sparse-mode
interface Vlan10
  ip pim sparse-mode
!
vrf context CISCO-CORP
  ip pim rp-address 10.255.100.1 group-list 224.0.0.0/4
```

### NEXUS-B (NX-OS)
```
feature pim
!
interface Ethernet1/8
  ip pim sparse-mode
interface Vlan10
  ip pim sparse-mode
!
vrf context CISCO-CORP
  ip pim rp-address 10.255.100.1 group-list 224.0.0.0/4
```

### Verify Part A (do this before Part B)

```
! IOS-XE
show ip pim neighbor          ! PBR-A expects 3 (Gi1/Gi2/Gi3); PBR-B expects 3
show ip pim rp mapping        ! Static: 10.255.100.1 for 224.0.0.0/4
show ip pim interface

! NX-OS
show ip pim neighbor vrf CISCO-CORP    ! CSWs expect 2; NEXUS boxes expect 1 (E1/8)
show ip pim rp vrf CISCO-CORP
show ip pim interface vrf CISCO-CORP brief
```

Nothing forwards yet — that's correct. PIM-SM is pull-based: no receivers, no tree.

---

## Part B — first stream (IGMPv2, Register, SPT)

Receiver goes on **PBR-B Gi1 first** because IOS-XE reliably answers pings to joined groups — a clean success gate before you involve NX-OS punting quirks.

### 1. Join the receiver — CORP-PBR-B
```
interface GigabitEthernet1
 ip igmp join-group 239.1.1.10
```

Immediately check the shared tree built toward the RP:
```
show ip mroute 239.1.1.10              ! on PBR-B: (*,G), RP 10.255.100.1, flags SJCL, OIF Gi1
show ip mroute vrf CISCO-CORP 239.1.1.10   ! on CSW2: (*,G) IIF E1/5, OIF E1/6
show ip mroute 239.1.1.10              ! on PBR-A (RP): (*,G) with OIF toward CSW2 (Gi3)
```
If CSW1 has the (*,G) instead of CSW2, your ECMP tiebreak landed differently — fine, just note which core switch owns the tree and mirror the Part E break accordingly.

### 2. Watch registration happen — on PBR-A
```
debug condition interface GigabitEthernet1
debug ip pim 239.1.1.10
```
(Conditional debug from your checklist, applied for real: the Register arrives as unicast from NEXUS-A via Gi1.)

### 3. Start the source — NEXUS-A
```
ping multicast 239.1.1.10 interface vlan 10 count 100
```
(If your NX-OS build rejects that syntax, try `ping 239.1.1.10 interface vlan 10 count 100`.)

**Expected:** replies from **10.10.71.2** (PBR-B's Gi1 — multicast pings are answered unicast by each joined responder). On PBR-A's debug: `Received v2 Register` then `Send v2 Register-Stop` — the FHR-to-RP handshake, once. Then `undebug all`.

### 4. Read the steady-state tree
```
! PBR-B
show ip mroute 239.1.1.10       ! now ALSO an (S,G): (10.1.0.1, 239.1.1.10), flags include T = SPT
show ip rpf 10.1.0.1            ! RPF neighbor 10.20.60.1 via Gi3 (the CSW2 prediction)
show ip mroute count            ! forwarded counters incrementing

! NX-OS hops
show ip mroute vrf CISCO-CORP detail   ! per-entry packet stats
```
The **(*,G) → Register → Register-Stop → (S,G)/SPT** sequence you just watched is the entire PIM-SM exam narrative in one ping.

---

## Part C — receiver on a real LAN SVI (NX-OS IGMP)

Now move the receiver where it belongs — site B's user VLAN:

### NEXUS-B
```
interface Vlan10
  ip igmp join-group 239.1.1.10
```

Re-run the source ping from NEXUS-A. Verify:
```
show ip igmp groups vrf CISCO-CORP          ! 239.1.1.10 on Vlan10, v2
show ip mroute vrf CISCO-CORP 239.1.1.10    ! on NEXUS-B: OIF Vlan10, IIF E1/8
```

Two NX-OS realities worth knowing (both exam-adjacent):
- `join-group` punts the traffic to the supervisor. N9Kv may or may not answer the pings — **the mroute counters are your proof of forwarding**, replies are a bonus.
- The production-grade alternative is `ip igmp static-oif 239.1.1.10` — adds the OIF without punting, switch won't reply at all. Swap it in and observe the difference if you like.

Optionally remove the PBR-B join now to keep state clean:
```
interface GigabitEthernet1
 no ip igmp join-group 239.1.1.10
```

---

## Part D — SSM with IGMPv3

Platform asymmetry to notice: **NX-OS enables the 232.0.0.0/8 SSM range by default** the moment PIM is on; **IOS-XE needs it switched on**.

### CORP-PBR-A and CORP-PBR-B
```
ip pim ssm default
```

### Receiver — NEXUS-B (IGMPv3 join with the source specified)
```
interface Vlan10
  ip igmp version 3
  ip igmp join-group 232.1.1.1 source 10.1.0.1
```

### Source — NEXUS-A
```
ping multicast 232.1.1.1 interface vlan 10 count 100
```

### Verify — the SSM signature
```
show ip mroute 232.1.1.1                     ! IOS: (S,G) ONLY - no (*,G), flags include s
show ip mroute vrf CISCO-CORP 232.1.1.1      ! NX-OS: same story
show ip pim group-range vrf CISCO-CORP       ! NX-OS: shows 232.0.0.0/8 = SSM
show ip igmp groups detail                   ! receiver: v3, include-mode, source 10.1.0.1
```
No (*,G), no Register, **RP never consulted** — that's the whole point of SSM, visible in one mroute.

---

## Part E — deliberate breaks

Restore each break before moving to the next.

### E1 — RPF failover (the one that matters)
With the source pinging continuously (`count 1000`):
```
! PBR-B — confirm current RPF path
show ip rpf 10.1.0.1                  ! expect via Gi3 / 10.20.60.1 (CSW2)

! Break it
interface GigabitEthernet3
 shutdown
```
**Expected:** a handful of lost replies, then the stream recovers. `show ip rpf 10.1.0.1` now shows Gi2 / 10.20.30.1 — the (S,G) rebuilt through CSW1, driven purely by the unicast table changing. Confirm CSW1 now carries the (S,G) it didn't have before. `no shutdown` and note the tree doesn't necessarily swing back until state times out — RPF follows unicast, but PIM isn't in a hurry.

### E2 — SSM without IGMPv3
```
! NEXUS-B
interface Vlan10
  ip igmp version 2
```
Try the 232.1.1.1 stream again. **Expected: dead.** A v2 join can't express a source, and the SSM range refuses (*,G) state — check `show ip mroute vrf CISCO-CORP 232.1.1.1` (nothing, or no OIF). This is the "SSM requires IGMPv3" exam fact, experienced. Restore `ip igmp version 3`.

### E3 — RP dependency (ASM vs SSM)
```
! PBR-B
no ip pim rp-address 10.255.100.1
```
**Expected:** new joins to 239.1.1.10 fail (PBR-B can't map group→RP, no shared tree), while 232.1.1.1 keeps flowing — SSM has no RP to lose. Restore the rp-address before Part F.

### E4 — static mroute: steering RPF without touching unicast
The GRE tunnel is PIM-capable but OSPF-expensive, so it never wins RPF. Force it:
```
! PBR-B — enable PIM on the tunnel (both ends)
interface Tunnel0
 ip pim sparse-mode
! (mirror on PBR-A Tunnel0)

! PBR-B — RPF for the source subnet now points into the tunnel
ip mroute 10.1.0.0 255.255.255.0 Tunnel0
```
**Expected:** `show ip pim neighbor` lists a neighbor on Tunnel0 (proof GRE carries multicast — native IPsec can't, GRE-over-IPsec can, a favourite exam distinction). `show ip rpf 10.1.0.1` now says Tunnel0 via static mroute, and the (S,G) rebuilds through the tunnel while unicast still uses the physical path — RPF and unicast **decoupled**. Remove with `no ip mroute 10.1.0.0 255.255.255.0 Tunnel0`. Leave PIM on the tunnels; it's harmless and useful later. (Don't lower the tunnel's OSPF cost to achieve this instead — the tunnel destination is learned via the same OSPF, and you'll build a recursive-routing flap.)

---

## Part F — MSDP anycast-RP (the stretch that teaches why MSDP exists)

Do this in the order written — the mid-point failure is the lesson.

### F1 — create the anycast condition (and watch ASM break)
```
! CORP-PBR-B
interface Loopback100
 description RP-ANYCAST
 ip address 10.255.100.1 255.255.255.255
 ip pim sparse-mode
!
router ospf 1
 network 10.255.100.1 0.0.0.0 area 0
```
Two routers now advertise 10.255.100.1/32; everyone uses their **closest** RP. Source (NEXUS-A) registers to PBR-A; receiver (NEXUS-B) joins toward PBR-B. Start the 239.1.1.10 stream: **it fails or goes one-way** — PBR-B is an RP that has never heard of the source. `show ip mroute 239.1.1.10` on PBR-B: (*,G) with receivers, no (S,G). That gap is precisely what MSDP fills.

### F2 — peer the RPs
```
! CORP-PBR-A
interface Loopback101
 ip address 10.255.101.1 255.255.255.255
router ospf 1
 network 10.255.101.1 0.0.0.0 area 0
ip msdp peer 10.255.101.2 connect-source Loopback101
ip msdp originator-id Loopback101

! CORP-PBR-B
interface Loopback101
 ip address 10.255.101.2 255.255.255.255
router ospf 1
 network 10.255.101.2 0.0.0.0 area 0
ip msdp peer 10.255.101.1 connect-source Loopback101
ip msdp originator-id Loopback101
```
```
show ip msdp summary        ! peer state Up (it's a TCP session, port 639)
show ip msdp sa-cache       ! on PBR-B once the source pings: (10.1.0.1, 239.1.1.10) learned from PBR-A
```
**Expected:** the moment the SA appears in PBR-B's cache, the stream completes. Register goes to one RP, MSDP tells the other, receiver-side RP joins toward the source.

### F3 — prove the redundancy
```
! CORP-PBR-A
interface Loopback100
 shutdown
```
Unicast reconverges, 10.255.100.1 now resolves to PBR-B everywhere, registration and joins shift there, stream survives. That's RP failover without touching a single client config. `no shutdown` after.

One-liner for the exam: NX-OS also offers a protocol-native alternative (`ip pim anycast-rp`, RFC 4610) that does this without MSDP — know it exists; MSDP is the one the blueprint names.

---

## Part G — BiDir PIM (describe-level, 10 minutes)

Consistent mapping everywhere, scoped to its own range:

```
! Both PBRs (IOS-XE)
ip pim bidir-enable
ip access-list standard BIDIR-GROUPS
 permit 239.200.1.0 0.0.0.255
ip pim rp-address 10.255.100.1 BIDIR-GROUPS bidir

! All four NX-OS boxes, under vrf context CISCO-CORP
  ip pim rp-address 10.255.100.1 group-list 239.200.1.0/24 bidir
```

Join 239.200.1.1 on NEXUS-B Vlan10, ping it from NEXUS-A, then look:
```
show ip pim rp mapping                        ! 239.200.1.0/24 -> Bidir Mode
show ip mroute 239.200.1.1                    ! (*,G) ONLY, B flag - even while traffic flows
```
**The takeaway:** traffic forwarding with *no (S,G) state ever created* — that's BiDir's entire value proposition (many-to-many with tiny state), and seeing the mroute makes it stick. Don't sink more time here; describe-level is all ENCOR asks.

---

## Troubleshooting quick hits

- Counters increment but no ping replies → normal on NX-OS join-group; trust `show ip mroute ... detail` / `show ip mroute count`. Put the join back on PBR-B Gi1 if you want replies.
- No (S,G) anywhere → check the FHR: does NEXUS-A's Vlan10 have `ip pim sparse-mode`? No PIM on the source interface = no Register.
- (*,G) exists, (S,G) RPF-fails → `show ip rpf <source>` hop by hop; nine times out of ten it's the ECMP pin on the "wrong" core switch or a missing sparse-mode on that path.
- PIM neighbor missing on one link → `show ip pim interface` both ends; on NX-OS confirm `feature pim` actually enabled.

## Rollback (complete removal)

```
! PBR-A / PBR-B
no ip msdp peer <peer>            (F)
no interface Loopback100          (A/F)
no interface Loopback101          (F)
no ip pim rp-address 10.255.100.1
no ip pim rp-address 10.255.100.1 BIDIR-GROUPS bidir
no ip pim ssm default
no ip pim bidir-enable
no ip mroute 10.1.0.0 255.255.255.0 Tunnel0
no ip multicast-routing distributed
! plus: no ip pim sparse-mode / no ip igmp ... under Gi1-3, Tunnel0
! and remove the two Loopback network statements under router ospf 1

! All four NX-OS boxes
no feature pim                    ! removes every pim/igmp interface + vrf command in one go
```

## Checklist mapping

| ENCOR line | Where you did it |
|---|---|
| PIM-SM | Parts A–B (Register/Register-Stop watched live) |
| IGMPv2 | Parts B–C |
| IGMPv3 | Part D receiver config |
| SSM | Part D + break E2 |
| Bidirectional PIM | Part G |
| MSDP | Part F (anycast-RP, break-then-fix) |
| Conditional debug (bonus) | Part B step 2 |
| RPF / static mroute (bonus) | E1, E4 |
