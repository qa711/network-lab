# Build this lab yourself: EVE-NG on a Windows PC

This guide takes you from a Windows PC to a running copy of the lab: EVE-NG installed, images added, the topology rebuilt and the configs loaded. It points at the configs, screenshots and runbooks in this repo.

*Last updated October 2026.*

## 1. What you'll build, and what you need

The full lab is about 45 nodes: three sites, a shared core, an MPLS provider network, an SD-WAN overlay, two firewalls, ISE, and an Ubuntu operations server. Running all of it at once needs a host in the 128 GB RAM class. You don't need that to start: build it in stages and grow into it.

**Before you begin, know four things:**

- **No images are provided.** Every Cisco and Palo Alto image here is licensed software, and you need your own (section 4).
- **There is no lab export file.** You rebuild the topology by hand from the screenshot at `docs/evidence/EVE-NG-Topology.png` (section 5), then load the configs.
- **The published configs are sanitised.** Every password, key and community has been replaced with a placeholder, and you put your own values in before they'll work (section 6).
- **Not every device has a published config.** `configs/` covers the campus, core and Site Q switches and routers, CE1 and CE2, and the three SD-WAN edge routers. PE1, PE2 and the P routers, the SD-WAN controllers, both firewalls, ISE and the WLC have none, so you build those from the vendors' guides and, for ISE, the AAA runbook.

The routers in `enarsi/configs/` belong to the ENARSI build, which is still in progress. This guide doesn't cover them yet.

**Hardware** (approximate; check each vendor's sizing guide for the versions you use)

| Build stage | Host RAM | CPU | Disk |
| --- | --- | --- | --- |
| Platform, core and campus (steps 1–2) | 32 GB | 8 threads with VT-x / AMD-V | 200 GB SSD |
| Adding WAN, SD-WAN and firewalls (steps 3–5) | 64 GB | 12+ threads | 350 GB SSD |
| Everything at once, including ISE | 128 GB | 16+ threads | 500 GB SSD |

ISE, vManage and the Nexus 9000v switches are the memory-hungry ones. You can run the lab in pieces: start only the nodes for the part you're working on.

**What costs money**

- **Free:** EVE-NG Community Edition, VMware Workstation Pro (personal use), Ubuntu, OPNsense, and the whole ops stack (LibreNMS, Oxidized, Akvorado, FreeRADIUS, tac\_plus).
- **Licensed:** all Cisco images (IOL, IOSv, CSR1000v, Nexus 9000v, XRv, the SD-WAN controllers and edges, ISE, C9800-CL) and the Palo Alto PA-VM.

**Suggested build order**

1. Platform: Windows prep, VMware, EVE-NG (sections 2–3)
2. Core and campus: CSW1/2, NEXUS-A/B, distribution and access switches, the two PBR routers
3. WAN: the MPLS PE/P routers, the CE routers, Site Q
4. SD-WAN: vManage, vSmart, vBond and the three edges
5. Security: Palo Alto, OPNsense, ISE, the WLC
6. Operations: the Ubuntu server and its stack (section 9)

Expect a weekend for the platform and core. The full build is weeks of evenings.

## 2. Prepare the Windows PC

EVE-NG runs as a virtual machine inside VMware Workstation, and the devices run as VMs inside that. This nesting only works if the CPU's virtualisation extensions reach VMware directly: Intel VT-x/EPT or AMD's equivalent is a mandatory requirement. [Source: EVE-NG](https://www.eve-ng.net/index.php/supported-hardware-and-software-systems/)

1. **Enable virtualisation in the BIOS/UEFI.** Reboot into firmware setup and turn on Intel VT-x (Intel) or SVM / AMD-V (AMD). Without it, EVE-NG installs but nodes won't start.
2. **Turn off the Windows hypervisor.** Windows features that use Hyper-V take the virtualisation extensions for themselves, and VMware can't nest. In an admin PowerShell:

    ```powershell
    Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
    Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
    bcdedit /set hypervisorlaunchtype off
    ```

3. **Turn off Memory Integrity.** Windows Security → Device security → Core isolation → Memory integrity: Off. This is virtualisation-based security, and it also holds the hypervisor.
4. **Reboot, then check.** Run `msinfo32`. At the bottom of System Summary you want *Virtualization Enabled in Firmware: Yes*, and **not** *A hypervisor has been detected*. If that line is still there, something above is still on.
5. **Install VMware Workstation Pro.** It's free with no licence key; you need a free Broadcom account to download it from the Broadcom Support Portal. [Source: Broadcom](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/release-notes/vmware-workstation-1763-pro-release-notes.html) EVE-NG supports Workstation 16.0 or later.
6. **Install the helper tools on Windows:** WinSCP (to copy images onto EVE-NG), and PuTTY or the EVE-NG Windows client pack (so console links open in a terminal).

**The trade-off:** turning off Hyper-V also breaks WSL2, Docker Desktop and Windows Sandbox, which depend on it. If you use those, you'll be switching between the two setups with a reboot. A dedicated machine, or EVE-NG installed directly on hardware, avoids this and runs faster.

## 3. Install EVE-NG Community Edition

Download the free Community Edition, build a VM in Workstation with nested virtualisation ticked, and give it as much RAM as you can spare. EVE-NG's own step-by-step for VMware is section 3.1 of the [EVE-NG Cookbook](https://www.eve-ng.net/index.php/documentation/professional-cookbook/); this is the short version.

1. **Download** the Community Edition ISO from the [EVE-NG download page](https://www.eve-ng.net/index.php/download/).
2. **Create the VM** in Workstation: Custom → *I will install the operating system later* → Linux, Ubuntu 64-bit.
3. **CPU:** as many cores as you can spare. Under Processors, tick **Virtualize Intel VT-x/EPT or AMD-V/RVI**. This one checkbox is what makes nested devices work.
4. **Memory:** as much as possible, leaving about 8 GB for Windows. RAM is what limits how much of the lab runs at once.
5. **Disk:** one virtual disk large enough for every image you'll add (see the table in section 1).
6. **Network adapter:** NAT to start self-contained, or Bridged to put EVE-NG on your home LAN.
7. **Install:** attach the ISO, boot, run the installer. On first boot EVE-NG asks for the root password, hostname and IP settings, and EVE-NG's [first-boot guide](https://www.eve-ng.net/index.php/documentation/installation/howto-configure-eve-during-first-boot/) walks through each prompt.
8. **Log in** to the web UI at the IP shown on the console. Change the default admin password straight away.
9. **Update** from the EVE-NG console in VMware Workstation: `apt update && apt upgrade`.

- [ ] Web UI loads from your Windows browser
- [ ] Default passwords changed (CLI and web)
- [ ] **Images and nodes work:** a node from any image you have starts and shows a console. That proves nesting works before you invest hours in images.

## 4. Get the images, upload and name them

Every Cisco and Palo Alto image here is licensed software, and the licence decides where you may run it. Free "image hub" sites redistribute these images without the vendors' permission, so this guide doesn't point to them.

**CML images can't be used in EVE-NG.** [Cisco Modeling Labs](https://developer.cisco.com/docs/modeling-labs/vm-images-for-cml-labs/) (CML) includes nearly every Cisco image this lab uses, but Cisco licenses those images only for use inside CML: "Downloading these VM images and using them outside Cisco Modeling Labs without a proper license is prohibited." That covers IOL, IOL L2, IOSv and XRv, which Cisco distributes with CML. For the other Cisco images, EVE-NG needs downloads from Cisco Software Central under an entitlement, such as an employer's support contract.

**No entitlement? Build the Cisco side in CML instead.** CML's reference platforms cover IOL, IOSv, CSR1000v, Nexus 9000v, IOS XRv 9000, Catalyst SD-WAN, C9800-CL and ISE, and it ships FreeRADIUS and TACACS+ containers too. The topology, configs and runbooks here carry over; only the platform changes. Check your CML edition's node limit, because the full lab is about 45 nodes.

| Image | Lab nodes | Get it from | EVE-NG folder | Disk file |
| --- | --- | --- | --- | --- |
| [Cisco IOL L2 17.12](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-iol-ios-on-linux/) | ASW/DSW-A and -B, the Q-SW switches | Distributed with CML, for use in CML only | `/opt/unetlab/addons/iol/bin/` (a `.bin` file, no folder) | none |
| [Cisco IOSv 15.9](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-vios-from-virl/) | Q-EDGE | Distributed with CML, for use in CML only | `vios-` | `virtioa.qcow2` |
| [Cisco CSR1000v 17.x](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-csrv1000-16-x-denali-everest-fuji/) | CORP-PBR-A/B | Cisco Software Central, with an entitlement | `csr1000vng-` | `virtioa.qcow2` |
| [CSR1000v for SD-WAN](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-csrv1000-sd-wan/) | Gret-Edge, Belv-Edge, Q-SDWANedge | Cisco Software Central, with an entitlement | `csr1000vng-` | `virtioa.qcow2` |
| [Cisco Nexus 9000v](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-nexus-9000v-switch/) | CSW1/2, NEXUS-A/B | Cisco Software Central, with an entitlement | `nxosv9k-` | `sataa.qcow2` |
| [Cisco XRv](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-xrv/) | CE1/CE2, PE1/PE2 | Distributed with CML, for use in CML only | `xrv-` | `hda.qcow2` |
| [SD-WAN controllers](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-viptela-images-set/) | vManage, vSmart, vBond | Cisco Software Central, with an entitlement | `vtmgmt-`, `vtsmart-`, `vtbond-` | `virtioa.qcow2` (vManage adds `virtiob.qcow2`) |
| [Cisco ISE 3.x](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-ise/) | ISE | Cisco Software Central, with an entitlement | `ise-` | `virtioa.qcow2` |
| [Cisco C9800-CL](https://www.eve-ng.net/index.php/documentation/howtos/cisco-wireless-c9800-cl/) | Gret-WLC | Cisco Software Central, with an entitlement | per the how-to | per the how-to |
| [Palo Alto PA-VM](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-palo-alto/) | PaloAlto | Palo Alto customer support portal | `paloalto-` | `virtioa.qcow2` |
| [OPNsense](https://www.eve-ng.net/index.php/documentation/howtos/opnsense-firewall/) | OPNsense-VPN | opnsense.org, free | per the how-to | per the how-to |
| [Ubuntu 24.04 Server](https://www.eve-ng.net/index.php/documentation/howtos/howto-create-own-linux-host-image/) | NOC-NMS-OPS | ubuntu.com, free | `linux-` | `virtioa.qcow2` |

Folder prefixes and disk names are from [EVE-NG's naming table](https://www.eve-ng.net/index.php/documentation/qemu-image-namings/). After the prefix you add your own version label, e.g. `nxosv9k-10.3.1`. The EIR-MPLS P routers have no published config, so use any IOS or IOS-XR router image you have.

**Upload each image**

1. Connect WinSCP to the EVE-NG IP as `root`.
2. Create the folder, e.g. `/opt/unetlab/addons/qemu/csr1000vng-17.3.8a/`, and copy the disk in.
3. Rename the disk to the name in the table. If the vendor ships a `.vmdk`, convert it on the EVE-NG console:

    ```bash
    qemu-img convert -f vmdk -O qcow2 image.vmdk virtioa.qcow2
    ```

4. Fix permissions. EVE-NG won't see the image without this:

    ```bash
    /opt/unetlab/wrappers/unl_wrapper -a fixpermissions
    ```

5. In a blank lab, add one node of that type and boot it before moving on to the next image.

## 5. Build the topology

There's no lab export file, so you recreate the topology by hand from the screenshot, one site at a time. It's the slowest step: about 45 nodes and their links. The screenshot is `docs/evidence/EVE-NG-Topology.png`, and the interface labels on every link are what you match.

1. **Create a new lab** in EVE-NG and give it a name.
2. **Add nodes with the exact names** from the screenshot: CSW1, NEXUS-A, CORP-PBR-A and so on. The configs, the Oxidized node list and the runbooks all refer to devices by those names.
3. **Set enough interfaces** when you add each node. The Nexus switches use Ethernet1/x ports well above 1/8, and the IOL switches need extra port groups for e0/0–e3/3. Too few, and links have nowhere to land.
4. **Connect links port for port as labelled.** The configs depend on the exact interfaces: a link on E1/5 instead of E1/6 leaves an IP address and an OSPF neighbour on a dead port.
5. **Build in the order from section 1:** the core first, then the campus switches and PBR routers. Get OSPF neighbours up in the core before adding the next site, so problems stay small.
6. **Export the lab** once it's built (More actions → Export). That file is your backup and your rebuild point.

**Sites at a glance**

| Site | Nodes |
| --- | --- |
| Core | CSW1, CSW2 (Nexus), CE1, CE2 (IOS XR) |
| EIR-MPLS | PE1, PE2 (IOS XR), and P routers EIR-MPLS-1–4, -A, -B |
| Gret A | Gret-Edge, NEXUS-A, CORP-PBR-A, DSW-A1/A2, ASW-A1–A3, Palo Alto, OPNsense, ISE, Gret-WLC, NOC-NMS-OPS |
| Belv B | Belv-Edge, NEXUS-B, CORP-PBR-B, DSW-B1/B2, ASW-B1–B3 |
| Site Q | Q-EDGE, Q-SDWANedge, Q-SW30–Q-SW34, Q-SW36 |
| SD-WAN | vManage, vSmart, vBond, a controller switch, an Internet router |

## 6. Load the configs

The configs in `configs/` are the real running configs with every secret replaced by a placeholder. Paste one as-is and the device rejects or mis-applies those lines, so replace each placeholder with your own value first.

**What you'll find, and what to put there**

| Placeholder | Was | Replace with |
| --- | --- | --- |
| `<REDACTED-KEY>` | TACACS+/RADIUS keys | Your AAA shared secrets, matching the server side |
| `<SNMP-COMMUNITY>` | SNMP v2c community | One read-only community, used everywhere |
| `<CERTIFICATE-REDACTED>` | Self-signed certificate blocks | Delete the line; the device generates its own |
| `<REDACTED>` | Local passwords and secrets | Your own admin and automation passwords |
| `<CONTACT>` | SNMP contact | Any address, or delete the line |
| `<SNMP-V3-KEY>` / `<SNMP-V3-PASS>` | SNMPv3 auth and priv keys | Cleartext passwords; NX-OS hashes them for you |
| `<TACACS-KEY>` | TACACS+ server key | The same value as your tac\_plus / ISE config |
| `<SERIAL>` | CSR1000v licence serial | Delete the line; it's generated per VM |
| `<PSK>` | IPsec pre-shared keys | One long random key, the same on both tunnel ends |

Any other placeholder in angle brackets is a secret too and gets the same treatment. The domain name has also been rewritten to `lab.internal`, which works as-is.

**Pick your values once, keep them in a file outside the repo, and reuse them.** Several secrets have to match across devices: both ends of a tunnel, every switch and the RADIUS server. Making them up per device is how logins break.

**Getting a config onto a node**

1. Boot the node and open its console from EVE-NG.
2. Fill in the placeholders in a copy of that device's file (they're named by management IP, e.g. `10.99.0.1` = NEXUS-A).
3. Paste in chunks of 20–30 lines rather than the whole file, because consoles drop characters on long pastes.
4. Save it: `write memory` (IOS/IOS-XE), `copy run start` (NX-OS), `commit` (IOS-XR).
5. Check: `show ip interface brief` and `show ip ospf neighbor` before moving to the next device.

The interface names in each config must match how you cabled the node in section 5. A mismatch is the most common reason a pasted config "doesn't work".

## 7. Connect the lab to your network

The lab reaches the outside world only through EVE-NG **cloud** networks, and how they meet your home network is yours to design. The author's home addressing and router setup aren't in this repo, and wouldn't fit your network anyway.

**How clouds map:** the *Management (Cloud0)* network is `pnet0`, bridged to the EVE-NG VM's first network adapter. *Cloud1* to *Cloud9* are `pnet1`–`pnet9`, bridged to the VM's second to tenth adapters. Add adapters in VMware to use them, and choose for each whether it's NAT, host-only or bridged to your LAN.

| Cloud in the screenshot | What it does here | Safe default |
| --- | --- | --- |
| Management | Out-of-band management for every device, and how the ops server reaches them | Host-only or NAT, private to your PC |
| Internet, SDWAN-Transit | Internet path for the SD-WAN controllers and edges | VMware NAT: outbound internet, nothing inbound |
| HomeLAN | The ops server's leg into a home network | Leave unconnected unless you want the ops server reachable from your LAN |
| GPoutside, WireGuard/IPsec VPN | The firewalls' outside interfaces for remote-access VPN | VMware NAT until you deliberately set up remote access (section 8) |

**Start with nothing bridged.** Everything on host-only or NAT means nothing in the lab can be reached from your LAN or the internet. Add a bridge only when you have a reason for it.

**Before you bridge anything, check two things:**

- **Addressing overlap.** The lab uses `10.x`, `172.16.12.x` and `192.168.x` ranges. If your home LAN sits in one of them, re-address one side first, or routing breaks in confusing ways.
- **DHCP leaking.** A lab device serving DHCP on a bridged network will hand addresses to your real devices. Check which lab interfaces run DHCP before bridging their segment.

## 8. Remote access and port forwarding: your router, your risk

**This guide doesn't configure your home router, and nothing in the lab needs it to work.** Remote access (reaching the lab from outside your home) is optional, and every port you forward is a door you've opened onto your home network. If you do it, you design it, and you own the result.

**How this lab does it, as a pattern (not values to copy):**

| Service | Forwarded port | Lands on |
| --- | --- | --- |
| GlobalProtect remote-access VPN | 443 TCP/UDP | Palo Alto outside interface |
| WireGuard | 51820 UDP | OPNsense |
| IPsec (IKE, NAT-T) | 500 and 4500 UDP | OPNsense |

Everything else (the EVE-NG web UI, LibreNMS, Oxidized, Akvorado, ISE, the firewall admin pages) is reached *through* a VPN, never forwarded directly.

**If you set up your own:**

- [ ] Forward only VPN ports. Never forward a management web interface.
- [ ] Require more than a password: certificate authentication, MFA, or both. A forwarded portal gets scanned within days. This lab's GlobalProtect logs show failed attempts from scanners in several countries, all stopped by the certificate requirement.
- [ ] Keep PAN-OS and OPNsense patched. An exposed VPN on an old build is the standing risk.
- [ ] Make the firewall rule between the lab and your home LAN deny-by-default, so a compromised lab VM can't reach your NAS, backups or personal machines.
- [ ] Test from outside: from a phone on mobile data, run `nmap -Pn -F <your WAN IP>`. Anything open beyond the VPN ports you chose is a finding.
- [ ] Don't be surprised by ports you didn't open. Some ISP routers answer on their own management ports (80, 443, 8080, 8443) from the WAN side. Those belong to the ISP's box, not your lab, and port forwarding can't close them.

**If you publish your own build,** keep your WAN IP, VPN keys, certificates and router screenshots out of it. Those are what turn a write-up into a map of your network.

## 9. The operations stack

The ops tools all run on one Ubuntu 24.04 Server node, NOC-NMS-OPS, on the management network. Install each tool from its own project documentation, then use the runbooks in `docs/runbooks/` for the lab-specific wiring. The runbooks carry placeholders for secrets too, so use the same values you chose in section 6.

| Tool | Job | Lab-specific guide in this repo |
| --- | --- | --- |
| LibreNMS | SNMP monitoring and alerting | Uses the SNMP community / v3 credentials from section 6 |
| Oxidized | Scheduled config backup into git | Poll each device once, by management IP. Its config file holds the device login, so keep it outside any repo and `chmod 600` it |
| Akvorado | NetFlow collection and analysis | `EVE-NG-SidePhase-Lab-Wide-Flows.md` |
| FreeRADIUS + Google Authenticator | RADIUS with phone-based one-time passwords | `EVE-NG-SidePhase-AAA-TACACS-RADIUS-OTP.md` |
| tac\_plus | TACACS+, built from source | Same AAA runbook, Part 0 |
| `scripts/lab-health.sh` | Health checks every 15 minutes | Needs `SNMP_COMMUNITY` and `RADIUS_LOCAL_SECRET` set in its environment |

**The phase runbooks** build the routing features in order once the topology is up:

1. `EVE-NG-Phase1-Filtering-PBR-Tunnel.md`: OSPF filtering, policy-based routing with IP SLA, the second GRE/IPsec tunnel
2. `EVE-NG-Phase2-Multicast.md`: PIM sparse-mode, SSM, anycast RP with MSDP
3. `EVE-NG-Phase3-Assurance-Automation.md`: QoS, NetFlow, RESTCONF/NETCONF, AAA, control-plane policing

**Publishing your own build?** `scripts/sanitize-configs.sh` strips secrets from Oxidized exports and audits the result, and `.gitleaks.toml` adds the lab-specific secret rules gitleaks misses by default. Run both before anything goes public.

## 10. Troubleshooting

Most failures come from four places: nesting, image naming, placeholders left in configs, and cabling that doesn't match the config.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Nodes start then stop at once; VMware says VT-x isn't supported | Hyper-V or Memory Integrity still holds the hypervisor, or the VT-x box isn't ticked | Redo section 2; `msinfo32` must not say "A hypervisor has been detected" |
| An image doesn't appear in the Add Node list | Wrong folder prefix or disk file name, or permissions not fixed | Check against the table in section 4, then run `unl_wrapper -a fixpermissions` |
| Console is blank for a long time | Some images boot slowly: Nexus 9000v, SD-WAN Manager and ISE take many minutes | Wait, and watch the node's CPU in EVE-NG; ISE is the slowest by far |
| Pasted config throws errors | A placeholder wasn't replaced, or an interface name doesn't exist on that node | Search the file for `<` before pasting; match interfaces to section 5 |
| OSPF neighbours don't form | Link on the wrong port, mismatched area, or MTU mismatch | `show ip ospf interface` on both ends; compare against the screenshot's port labels |
| RADIUS test times out instead of rejecting | Service not running, or the client secret doesn't match | Run `freeradius -X` in the foreground and watch the packet arrive |
| Akvorado drops flows as "metadata missing" | Its SNMP poll to the exporter's source address is failing | Check the community and the device's SNMP ACL; the flows runbook explains the check |
| SD-WAN edges won't join the controllers | Certificates, organisation name or vBond reachability | Follow EVE-NG's [SD-WAN images how-to](https://www.eve-ng.net/index.php/documentation/howtos/howto-add-cisco-viptela-images-set/) for the certificate setup |
| Throughput is tiny on CSR1000v or PA-VM | Unlicensed images run throttled or with limited features | Expected in a lab; apply an evaluation licence if a test needs more |
| Everything is sluggish | More nodes running than RAM allows, so the host is swapping | Stop nodes you're not using and run the lab in parts |

## Sources

- [EVE-NG: supported hardware and software](https://www.eve-ng.net/index.php/supported-hardware-and-software-systems/)
- [EVE-NG: QEMU image naming](https://www.eve-ng.net/index.php/documentation/qemu-image-namings/)
- [EVE-NG: virtual machine install](https://www.eve-ng.net/index.php/documentation/installation/virtual-machine-install/)
- [Broadcom: VMware Workstation 17.6.3 Pro release notes](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/release-notes/vmware-workstation-1763-pro-release-notes.html)
- [Cisco DevNet: VM images for CML labs](https://developer.cisco.com/docs/modeling-labs/vm-images-for-cml-labs/)
