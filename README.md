# WireGuard Lab -- Infrastructure as Code

Multi-site home lab with a WireGuard VPN tunnel connecting two real sites:
a primary residence (site A, "home") and a secondary residence (site B, "cottage").

Site A runs on a Debian 12 / KVM / OVS stack inside VMware Fusion on a Mac Intel.
Site B runs on a Raspberry Pi 4 with Alpine Linux.

---

## Architecture overview

```
Internet (real public IP)
     |
     |-- Port forward UDP XXXX1 --> Mac Intel NIC --> h-bastion WAN
     |-- Port forward UDP XXXX2 --> Pi 4 eth1    --> c-bastion WAN
     |
     +===========================  WireGuard tunnel  ===========================+
     |                                                                          |
     |  Site A -- home                          Site B -- cottage               |
     |  Mac Intel (VMware Fusion)               Raspberry Pi 4 (Alpine)         |
     |                                                                          |
     |  h-server00 (Debian 12 / KVM)            (no KVM -- single Pi 4)         |
     |    |                                       |                             |
     |    +-- h-bastion (Alpine KVM)              +-- bastion namespace          |
     |    |   WAN: 192.168.0.250                      WAN (eth1 USB): varies    |
     |    |   DMZ: 10.0.1.1/30                        DMZ (veth): 10.1.1.1/30   |
     |    |   wg0: 10.0.0.1/30 <----tunnel----->      wg0: 10.0.0.2/30          |
     |    |                                                                      |
     |    +-- h-router00 (Alpine KVM)            +-- router00 namespace          |
     |    |   DMZ:   10.0.1.2/30                     DMZ (veth): 10.1.1.2/30    |
     |    |   LAN10: 10.0.10.1                        LAN (eth0 RJ45): 10.1.10.1 |
     |    |   VLAN20: 10.0.20.1                                                  |
     |    |   VLAN30: 10.0.30.1                                                  |
     |    |                                                                      |
     |    +-- h-demo-lan10/20/30 (Alpine KVMs)                                  |
     |                                                                          |
     +=========================================================================+
```

### Site B network namespaces on the Pi 4

The Pi 4 runs both bastion and router00 as Linux network namespaces rather than
separate VMs. A veth pair (v-bastion / v-router00) acts as the DMZ link between
the two namespaces. The physical interfaces are moved into their respective
namespaces at boot -- the default namespace holds no production IP.

```
Pi 4 (Alpine)
  default ns
    |-- fmp-d (management veth, for host SSHD only)
    |
    +-- bastion ns
    |     eth1 (USB dongle)  --> ISP modem / WAN
    |     v-bastion          --> veth DMZ link
    |     wg0                --> WireGuard tunnel to site A
    |
    +-- router00 ns
          eth0 (integrated)  --> home network LAN / Google Nest
          v-router00         --> veth DMZ link
          dnsmasq            --> DHCP + DNS for site B
```

---

## Repository layout

```
.
|-- site-A.env                        Site A public config    [git-tracked]
|-- site-A-real-ce.env                Site A with real CE     [git-tracked]
|-- site-B.env                        Site B public config    [git-tracked]
|-- site-B-real-ce.env                Site B with real CE     [git-tracked]
|-- site-B-pi4-atCottage.env          Site B Pi 4 at cottage  [git-tracked]
|-- site-B-pi4-simulationAtHome.env   Site B Pi 4 sim at home [git-tracked]
|
|-- secrets-A.env                     [gitignored -- fill from template]
|-- secrets-A-real-ce.env             [gitignored]
|-- secrets-B.env                     [gitignored]
|-- secrets-B-real-ce.env             [gitignored]
|-- secrets-B-pi4.env                 [gitignored]
|-- secrets-pi4-wg0-core.conf         [gitignored]
|
|-- secrets-A.env.template
|-- secrets-B.env.template
|-- secrets-B-pi4.env.template
|-- secrets-pi4-wg0-core.conf.template
|
|-- preseed.cfg.tmpl                  Debian preseed template
|-- 01-create-jmp00.sh                Mac Intel: creates jmp00 VMware VM
|-- 02-create-server00.sh             Mac Intel: builds preseed ISO
|-- 03-packages.sh                    Host: KVM / OVS / libvirt packages
|-- 04-network.sh                     Host: OVS + netplan bridges
|-- 05-libvirt-nets.sh                Host: libvirt networks
|-- 06-libvirt-config.sh              Host: libvirt suspend/resume config
|-- 07-create-bastion.sh              KVM: WireGuard bastion
|-- 08-create-router00.sh             KVM: DHCP / DNS / routing
|-- 09-create-demo-vms.sh             KVM: demo VMs on LAN10, VLAN20, VLAN30
|-- 10-bastion-router00-on-pi4.sh     Pi 4: full automated setup (site B)
|
|-- pi4-bootstrap.md                  Alpine install procedure for the Pi 4
|-- ce-notes.md                       Legacy simulated CE notes (historical)
|-- update-alpine-image.sh            Updates the shared Alpine base image
```

---

## Deployment -- site A (home, Mac Intel + KVM)

### Prerequisites

- VMware Fusion on Mac Intel
- jmp00 running (bootstrap gateway and SSH ProxyJump entry point)
- WireGuard keys generated (see Secret management below)

### jmp00 -- do once, keep running

jmp00 is a permanent Alpine VMware VM. It provides internet access to the KVM
hosts during rebuilds and serves as the SSH ProxyJump entry point into both sites.

```sh
source secrets-A.env
bash 01-create-jmp00.sh
```

Copy the output bundle to your Mac and start with vmrun. See the script header
for the exact vmrun command.

Add to `~/.ssh/config` on your Mac:

```
Host jmp00
    HostName 192.168.86.231
    User lab
    ForwardAgent yes

Host *.home.lab
    ProxyJump jmp00
    User lab

Host *.cottage.lab
    ProxyJump jmp00
    User lab
```

### VMware network assignments (Mac Intel)

```
vmnet6    10.0.10.0/24   site A LAN      (h-server00 br-ext, jmp00 eth1)
vmnet7    10.1.10.0/24   site B LAN sim  (c-server00 br-ext, jmp00 eth2)
vmnet11   bridged Wi-Fi  management      (jmp00 eth0, server br-mgmt-access)
```

One additional vmnet bridges the Mac's physical RJ45 NIC so h-bastion can
reach the real ISP router. The exact vmnet number is set in `site-A-real-ce.env`
as `IF_ISP_REAL`.

### Build and deploy site A

```sh
# 1. Preseed ISO (run on Mac Intel)
source site-A-real-ce.env && source secrets-A-real-ce.env
bash 02-create-server00.sh

# 2. Create VM in VMware Fusion, attach ISO, boot (fully automated install)
#    NIC 1: vmnet6 (LAN)  NIC 2: real-CE vmnet (WAN)  NIC 3: vmnet11 (mgmt)

# 3. Host setup (run on h-server00)
sudo bash 03-packages.sh
source site-A-real-ce.env && source secrets-A-real-ce.env
sudo -E bash 04-network.sh && sudo netplan apply
sudo bash 05-libvirt-nets.sh
sudo bash 06-libvirt-config.sh

# 4. KVM setup (run on h-server00)
source site-A-real-ce.env && source secrets-A-real-ce.env
bash 07-create-bastion.sh
bash 08-create-router00.sh
bash 09-create-demo-vms.sh
```

---

## Deployment -- site B (cottage, Raspberry Pi 4)

See `pi4-bootstrap.md` for the Alpine install on the Pi 4.

Once Alpine is installed and the Pi is accessible:

```sh
# 1. Fill in secret files from templates
cp secrets-B-pi4.env.template         secrets-B-pi4.env
cp secrets-pi4-wg0-core.conf.template secrets-pi4-wg0-core.conf
# edit both files -- WireGuard keys, peer endpoint, SSH public key

# 2. Copy all required files to the Pi
scp site-B-pi4-atCottage.env \
    secrets-B-pi4.env \
    secrets-pi4-wg0-core.conf \
    10-bastion-router00-on-pi4.sh \
    root@<pi4-ip>:/root/

# 3. Run the setup script on the Pi (as root)
ash /root/10-bastion-router00-on-pi4.sh
```

The script installs packages, writes all config files, enables startup at boot,
and reboots when done. After the reboot run `/root/lab/test.sh` to verify.

---

## Real-CE port forwarding

Both bastions connect to the internet through your home ISP router. The router
needs two UDP port forwards, both pointing at the Mac's physical NIC IP on
the home LAN:

| Forward | UDP port | Destination        | Destination port | Bastion     |
|---------|----------|--------------------|------------------|-------------|
| WG-A    | XXXX1    | Mac Intel LAN IP   | 51820            | h-bastion   |
| WG-B    | XXXX2    | Pi 4 WAN IP (eth1) | 51820            | c-bastion   |

The exact ports and IPs are stored in `secrets-A-real-ce.env` and
`secrets-B-pi4.env` (both gitignored) as `WG_PEER_ENDPOINT`.

---

## Secret management

```sh
# 1. Copy templates
cp secrets-A.env.template         secrets-A.env
cp secrets-B-pi4.env.template     secrets-B-pi4.env
cp secrets-pi4-wg0-core.conf.template secrets-pi4-wg0-core.conf

# 2. Generate WireGuard key pairs
wg genkey | tee wg-A.key | wg pubkey > wg-A.pub
wg genkey | tee wg-B.key | wg pubkey > wg-B.pub

# 3. Generate the lab SSH key
ssh-keygen -t ed25519 -f ~/.ssh/lab_ed25519 -C "lab@lab"

# 4. Fill in secrets files:
#    secrets-A.env:              site A private key, site B public key, site B endpoint
#    secrets-B-pi4.env:          site B private key, site A public key, site A endpoint, SSH pubkey
#    secrets-pi4-wg0-core.conf:  site B private key, site A public key, site A endpoint
```

All `secrets-*.env` and `secrets-*.conf` files are in `.gitignore`.
Never commit them.

---

## End-to-end sanity checks

```sh
# From Mac (via jmp00 ProxyJump)
ssh h-demo-lan30.home.lab traceroute c-router00.cottage.lab

# Expected path:
#   1  h-router00-vlan30   10.0.30.1
#   2  h-bastion-dmz       10.0.1.1
#   3  c-bastion-wg        10.0.0.2
#   4  c-router00-dmz      10.1.1.2

# WireGuard handshake (site A)
ssh h-bastion.home.lab sudo wg show

# WireGuard handshake (site B -- via ProxyJump through router00 ns)
ssh -J lab@<pi4-lan-ip> lab@<fmp-d-ip> sudo ip netns exec bastion wg show

# Inter-site DNS
ssh h-router00.home.lab nslookup c-router00.cottage.lab
ssh -J lab@<pi4-lan-ip> lab@<fmp-d-ip> sudo ip netns exec router00 nslookup h-router00.home.lab
```

---

## Naming conventions

All hostnames follow the pattern `${SITE_LETTER}-<role>`:

| Component        | Site A (home)      | Site B (cottage)          |
|------------------|--------------------|---------------------------|
| KVM host (Debian)| h-server00         | -- (Pi 4, no KVM host)    |
| WireGuard bastion| h-bastion          | c-bastion (namespace)     |
| DHCP/DNS router  | h-router00         | c-router00 (namespace)    |
| Demo VMs         | h-demo-lan10/20/30 | -- (not on Pi 4)          |
| Bootstrap VM     | jmp00              | jmp00 (shared)            |

The site name, letter prefix, and domain are just variables in the env files
and can be changed freely.

---

## Alpine base image

All Alpine VMs (KVM and jmp00) use the cloud-init NoCloud image:

```
Source: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/
File:   nocloud_alpine-3.23.3-x86_64-bios-cloudinit-r0.qcow2
```

`update-alpine-image.sh` patches and upgrades the image before use.
The Pi 4 uses a separate ARM Alpine image (see `pi4-bootstrap.md`).

---

## Historical note -- simulated CE routers

Early versions of this lab used two OpenWRT VMs (h-ce, c-ce) to simulate
ISP CPE routers on a VMware NAT network. They forwarded WireGuard UDP traffic
to the bastions and gave the lab a realistic NAT traversal scenario without
requiring a real internet connection.

Those VMs have been retired. Both bastions now connect through real port
forwards on the home ISP router and use the real public IP as the WireGuard
endpoint. The OpenWRT setup notes are preserved in `ce-notes.md` for reference.
The env files `site-A-real-ce.env` and `site-B-real-ce.env` replaced the
original `site-A.env` / `site-B.env` for the real-internet topology.
