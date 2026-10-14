# Verify It Yourself

Every claim in the overview, with the command that proves or disproves it. Don't take any of it on trust.

Two ways to use this:

- **With read-only access to the lab:** run the commands in the *Live* sections. Everything here is read-only; nothing changes configuration.
- **With only this repository:** the *From the repo* sections show how to check the same claims against the published configs using `grep`. Slower, but it works from a laptop with no access at all. Configs are saved under each device's management address, so CORP-PBR-A is `configs/10.99.250.250` and NEXUS-A is `configs/10.99.0.1`.

If something doesn't match what's written, that's worth telling me about. Several of the problems listed in the overview's "what's wrong with it" section were found exactly this way.

---

## Getting in (if you have access)

```bash
ssh guest-ro@10.99.0.1        # NEXUS-A: campus switch, Gret A
ssh guest-ro@10.99.250.250    # CORP-PBR-A: core router, most of the interesting features
ssh guest-ro@10.99.2.1        # Q-EDGE: branch router
```

The account is read-only and enforced per command. Try `configure terminal` and you'll be refused. That refusal is itself one of the claims being tested, so it's a reasonable first thing to do.

---

## 1. "Four separate routing domains (VRFs)"

**Claim:** user, industrial and management traffic are in genuinely separate routing tables, not just filtered.

**Live**
```
show vrf                                    ! NX-OS: lists CISCO-CORP, SCADA, PLc, DMZ
show ip route summary vrf CISCO-CORP
show ip route summary vrf SCADA
```

**What proves it:** each VRF has its own route count and its own prefixes. A route in `SCADA` does not appear in `CISCO-CORP`. That's separation at the routing-table level: the switch cannot forward between them even if it wanted to.

**Quick disproof attempt:** pick an address you can see in `SCADA` and look for it in the other table:
```
show ip route 10.69.0.0 vrf CISCO-CORP      ! expect: not found
```

**From the repo**
```bash
grep -c "^vrf context" configs/10.99.0.1                       # NEXUS-A
grep -A3 "^vrf context SCADA" configs/10.99.1.251              # CSW1
```

---

## 2. "OSPF with proper area design"

**Claim:** the campus switches are area border routers, summarising site networks into the core.

**Live** on NEXUS-A:
```
show ip ospf vrf CISCO-CORP | include Area|border
show ip ospf neighbors vrf CISCO-CORP
show ip ospf database summary vrf CISCO-CORP
```

**What proves it:** the switch reports itself as an area border router, has neighbours in more than one area, and the summary database contains type-3 entries it generated. If it only had area 0 interfaces, none of that would be there.

**From the repo**
```bash
grep -E "area 0.0.0.(10|20)" configs/10.99.0.1 configs/10.99.1.1   # NEXUS-A, NEXUS-B
grep -E "area .* range" configs/10.99.0.1                     # NEXUS-A
```

---

## 3. "Policy-based routing with automatic failover"

**Claim:** certain user traffic is forced down a chosen path, and moves automatically if that path fails.

**Live** on CORP-PBR-A:
```
show ip policy                              ! which interface has the policy
show route-map PBR-POLICY                   ! the rules, and how many packets matched
show ip sla summary                         ! the probes watching each path
show track brief                            ! up/down state driving the failover
```

**What proves it:** the route-map shows a non-zero match count (traffic really is being policy-routed, not just configured), the SLA probes show `OK`, and the tracked objects show `Up`.

⚠️ **This is one of the honest failures.** The design was for two user networks to take *different* core switches. A review found the next-hops entered in the wrong order, so both were using the same one. Check whether it's been fixed:

```
show route-map PBR-POLICY | include next-hop
```

Sequence 10 and sequence 20 should prefer *different* first next-hops. If they both prefer the same one, the fix hasn't landed yet, and you've just verified a documented fault rather than a claim.

**From the repo**
```bash
grep -A4 "route-map PBR-POLICY permit" configs/10.99.250.250   # CORP-PBR-A
```

---

## 4. "Multicast working across three sites"

**Claim:** PIM sparse-mode with two routers sharing one rendezvous-point address, linked by MSDP.

**Live** on CORP-PBR-A:
```
show ip pim neighbor                        ! PIM adjacencies
show ip pim rp mapping                      ! the rendezvous point in use
show ip msdp summary                        ! peering with the other RP: state should be Up
show ip mroute                              ! actual multicast forwarding state
```

**What proves it:** `show ip msdp summary` in `Up` state means the two rendezvous points are exchanging source information. That's the mechanism that makes anycast RP work. `show ip mroute` showing `(S,G)` entries means real traffic is being forwarded, not just protocol state.

**The interesting one:** run `show ip pim rp mapping` on CORP-PBR-**B** too. Both routers claim the same RP address, `10.255.100.1`. That's intentional: whichever is closer serves each device, and MSDP keeps them in sync.

**From the repo**
```bash
grep -E "rp-address|msdp" configs/10.99.250.250 configs/10.99.250.251   # CORP-PBR-A, CORP-PBR-B
```

---

## 5. "Encrypted tunnels over two different paths"

**Claim:** two GRE-over-IPsec tunnels between the core routers, taking physically different routes.

**Live**
```
show crypto session                         ! expect two sessions, different peers
show ip interface brief | include Tunnel
show ip ospf neighbors | include Tunnel
show interface Tunnel0 | include MTU
```

**What proves it:** two separate crypto sessions in `UP-ACTIVE`, both tunnels running a routing protocol inside them, and an MTU of 1400 rather than the default 1500. That last one is what stops large packets silently vanishing.

**From the repo**
```bash
grep -A8 "^interface Tunnel" configs/10.99.250.250            # CORP-PBR-A
```

---

## 6. "Quality of service that actually does something"

**Claim:** traffic is marked, prioritised and queued, with counters to prove it.

**Live** on CORP-PBR-A:
```
show policy-map interface GigabitEthernet1 input     ! marking
show policy-map interface GigabitEthernet2 output    ! queuing and shaping
```

**What proves it:** packet counters incrementing per class. A QoS policy with zero counters everywhere is configured but doing nothing, which is the normal state of most lab QoS.

⚠️ **Another documented fault to check.** A 1 Mbps shaper was applied for a test and left behind, rate-limiting all inter-site traffic. Look at the parent class:

```
show policy-map interface GigabitEthernet2 output | include shape|rate
```

If it shows a 1000000 target rate, the leftover is still there.

---

## 7. "Login requires a password *and* a phone code"

**Claim:** multi-factor authentication on network device logins.

**Live:** this one needs your own account rather than the guest one, so it's more of a demonstration than a self-service test. What you can verify independently:

```
show running-config | include tacacs|radius|aaa authentication
```

**What proves it:** the device points at both an ISE server and a RADIUS server, and every authentication list ends with `local`. That last word is the fallback that stops an authentication server outage locking everyone out permanently.

**The bit worth understanding:** the device itself knows nothing about one-time passwords. It sends the password to ISE, ISE forwards it to FreeRADIUS, and FreeRADIUS splits off the last six digits and checks them against the clock. No protocol changes anywhere, which is why this approach has worked since the 1990s.

**From the repo**
```bash
grep -E "aaa authentication|aaa authorization" configs/10.99.2.39   # Q-SW39
```

Note every list ends in `local`. That's deliberate and it's the single most important habit in AAA rollouts.

---

## 8. "Per-command authorisation"

**Claim:** a read-only user can log in and still be denied configuration commands.

**Live:** the best test in this document, because you can run it on yourself:

```
show ip interface brief          ! works
ping 10.99.0.1                   ! works
configure terminal               ! "Command authorization failed"
```

**What proves it:** the login succeeded (you're at a prompt), but a specific command was refused. Authentication and authorisation are separate steps, and this is what the difference looks like in practice. Every command you type is checked against a server in real time.

---

## 9. "NetFlow is being collected"

**Claim:** three devices export traffic summaries to a collector.

**Live**
```
show flow monitor FNF-MONITOR statistics     ! flows added, aged
show flow exporter FNF-EXPORTER statistics   ! packets actually sent
show flow monitor FNF-MONITOR cache format table | head -20
```

**What proves it:** the cache shows real conversations with byte and packet counts. Note that the *monitor* having flows and the *exporter* sending packets are two different things. A working cache with a zero export counter means the collector is receiving nothing, which is a failure mode I hit and didn't notice for a while.

---

## 10. "Control plane protection"

**Claim:** the branch router limits traffic to its own processor.

**Live** on Q-EDGE:
```
show policy-map control-plane
```

**What proves it:** counters incrementing per class. Routing protocol traffic should be classified but not rate-limited (limiting it would break adjacencies); management traffic is limited.

**Contrast worth seeing:** the same idea on a Nexus, where it's on by default and can't be turned off:
```
show copp status                             ! on CSW1
```

---

## Things you can safely break

If you have access and want to see the network react, these are reversible and won't damage anything. Ask first, as I may want to watch.

| Test | What to run | What should happen |
|---|---|---|
| **Path failover** | Shut one core-facing interface while pinging between sites | A few dropped packets, then recovery via the other core switch. `show track brief` flips to Down. |
| **Rendezvous point failover** | Shut `Loopback100` on one PBR router | Multicast keeps flowing. The other router's copy of the anycast address takes over. |
| **Authentication fallback** | Stop the RADIUS service | The one-time-password account fails; the local account still works after a short pause. This is why `local` is on every list. |
| **Replay protection** | Log in with a one-time code, then immediately reuse the same code | Rejected. Codes are single-use, and this check silently stopped working twice during the build, which is why it's now monitored. |

---

## If you find something wrong

Genuinely, please say. The configs are published from the live devices, so what's here is what was running at the last sync, including anything broken at the time. Two of the faults documented in the overview were found by re-reading my own configs weeks later, and I'd rather know about the third.
