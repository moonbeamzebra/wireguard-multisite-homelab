# WireGuard Multi-Site Home Lab -- Infrastructure as Code

Two-site home lab connected by a WireGuard VPN tunnel over the real internet.
Both sites run identical hardware (GMKtec M7 Ultra, Ryzen 6850U, 32 GB DDR5)
with Debian 13 / KVM / Open vSwitch.

```
Internet (real public IP -- home ISP)
     |
     +-- UDP XXXX1 --> m-server00 NIC --> m-bastion WAN
     +-- UDP XXXX2 --> c-server00 NIC --> c-bastion WAN
     |
     +======================  WireGuard tunnel  =====================+
     |                                                               |
     |  Site A -- maison                  Site B -- chalet          |
     |  GMKtec M7 Ultra / Debian 13 KVM   GMKtec M7 Ultra / Debian 13 KVM
     |                                                               |
     |  m-server00 (KVM host)             c-server00 (KVM host)    |
     |  |                                 |                         |
     |  +-- m-bastion (Alpine)            +-- c-bastion (Alpine)    |
     |  |   WAN: 192.168.0.250            |   WAN: 192.168.0.251    |
     |  |   DMZ: 10.0.1.1/30             |   DMZ: 10.1.1.1/30      |
     |  |   wg0: 10.0.0.1 <---tunnel---> |   wg0: 10.0.0.2         |
     |  |                                 |                         |
     |  +-- m-router00 (Alpine)           +-- c-router00 (Alpine)   |
     |      DMZ:   10.0.1.2/30               DMZ:   10.1.1.2/30    |
     |      LAN5:  10.0.5.1                  LAN5:  10.1.5.1        |
     |      LAN10: 10.0.10.1                 LAN10: 10.1.10.1       |
     |      LAN20: 10.0.20.1                 LAN20: 10.1.20.1       |
     |      LAN30: 10.0.30.1                 LAN30: 10.1.30.1       |
     |                                                               |
     +===============================================================+
```

---

## Network layout

| Segment | Site A       | Site B       | Interface     | Role                          |
|---------|--------------|--------------|---------------|-------------------------------|
| LAN5    | 10.0.5.0/24  | 10.1.5.0/24  | eth3 (dongle) | Server room / patch panel     |
| LAN10   | 10.0.10.0/24 | 10.1.10.0/24 | eth1 (RJ45)   | Infrastructure / Google Nest  |
| VLAN20  | 10.0.20.0/24 | 10.1.20.0/24 | eth2.20 (OVS) | Application subnet            |
| VLAN30  | 10.0.30.0/24 | 10.1.30.0/24 | eth2.30 (OVS) | Application subnet            |
| DMZ     | 10.0.1.0/30  | 10.1.1.0/30  | eth0          | Bastion <-> Router00          |
| WG      | 10.0.0.1/30  | 10.0.0.2/30  | wg0           | Inter-site tunnel             |

LAN5 and LAN10 use Linux bridges (br-ext5, br-ext10).
VLAN20 and VLAN30 use Open vSwitch (ovs-lab) with 802.1Q tagging.

**Access control (iptables on router00):**
- LAN10 (infrastructure): full access to router, all subnets, and tunnel
- LAN5, VLAN20, VLAN30 (application): DHCP and DNS only to router;
  can reach the tunnel and each other but not LAN10 (infrastructure isolation)

---

## Repository layout

```
site-A.env                              Site A public config            [git-tracked]
site-B.env                              Site B public config            [git-tracked]
site-A-secrets.env                      Site A secrets                  [gitignored]
site-B-secrets.env                      Site B secrets                  [gitignored]
site-specific-secrets.env.template      Template for secret files

preseed.cfg.tmpl.debian13.amd64.wifi.GMKtec   Debian preseed template

01-create-server00.sh        Build preseed ISO for bare metal install
02-packages.sh               Host: install packages and base config
03-download-update-alpine-image.sh    Download and update Alpine cloud image
04-download-update-debian-image.sh    Download and update Debian 13 cloud image
05-network.sh                Host: configure bridges (Linux + OVS)
06-libvirt-nets.sh           Host: define libvirt networks
07-libvirt-config.sh         Host: configure libvirt shutdown behavior
08-create-bastion.sh         Deploy WireGuard bastion VM (Alpine)
09-create-router00.sh        Deploy DHCP/DNS/routing VM (Alpine)
10-create-demo-vms-alpine.sh Deploy Alpine demo client VMs
11-create-demo-vms-debian.sh Deploy Debian 13 demo client VMs
12-host-hardening.sh         Host SSH and iptables hardening (dev/prod mode)

patch-router00-iptables.sh   Utility: apply iptables to an existing router00 VM

GMKtec-M7-Ultra.md           Hardware reference: BIOS config, NIC IDs, validation
```

---

## Deployment

### Prerequisites

- Two GMKtec M7 Ultra machines with Debian 13 installed
  (use `01-create-server00.sh` to build the preseed ISO)
- WireGuard keys generated (see Secret management below)
- `site-A-secrets.env` and `site-B-secrets.env` filled in from the template
- SSH access to both server00 hosts

### Step 1 -- Build and write the preseed ISO (per site)

```sh
source site-A.env && source site-A-secrets.env
bash 01-create-server00.sh
# Write to USB: dd if=debian-13-preseed-amd64-maison.iso of=/dev/sdX bs=4M status=progress
```

See `GMKtec-M7-Ultra.md` for BIOS settings required before booting from USB.

### Step 2 -- Host packages and base config (run on server00)

```sh
source site-A.env && source site-A-secrets.env
sudo -E bash 02-packages.sh
```

### Step 3 -- Download base images

Run before `05-network.sh` because after that step internet access requires
router00 to be running.

```sh
# Temporarily point DNS at 8.8.8.8 for the download
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf

bash 03-download-update-alpine-image.sh
bash 04-download-update-debian-image.sh
```

### Step 4 -- Host networking and libvirt

```sh
sudo -E bash 05-network.sh
sudo reboot
# After reboot:
sudo bash 06-libvirt-nets.sh
sudo bash 07-libvirt-config.sh
```

### Step 5 -- Deploy KVM VMs

```sh
source site-A.env && source site-A-secrets.env

bash 08-create-bastion.sh
# Wait ~90s for cloud-init to finish, then verify:
#   virsh console m-bastion -> sudo wg show   (expect: recent handshake)

bash 09-create-router00.sh
# Wait ~90s, then verify:
#   virsh console m-router00 -> sudo dnsmasq --test

bash 10-create-demo-vms-alpine.sh
bash 11-create-demo-vms-debian.sh
```

### Step 6 -- Host hardening

```sh
source site-A.env
# During development (WiFi SSH access kept):
sudo -E bash 12-host-hardening.sh dev

# Once Google Nest is connected to LAN10 at the final site:
sudo -E bash 12-host-hardening.sh prod
```

Repeat all steps on site B (source site-B.env && source site-B-secrets.env).

---

## SSH access

All VMs are reached via ProxyJump through server00. The Mac connects to
server00 directly over LAN10 (via the Google Nest).

`~/.ssh/config` on the Mac:
```
Host 10.0.* 10.1.* m-server00 m-router00 m-bastion m-demo-*lan* \
     c-server00 c-router00 c-bastion c-demo-*lan*
    User lab
    IdentityFile ~/.ssh/id_ed25519_lab-maison-chalet
    ForwardAgent yes
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile ~/.ssh/known_hosts.lab-maison-chalet
```

The Mac resolv.conf (or macOS network DNS settings) should include the lab
search domains:
```
search maison.lab chalet.lab
```

---

## ISP port forwarding

Both bastions connect through the site A ISP router. Two UDP port forwards
are required:

| Rule | External port | Destination          | WG port | Bastion   |
|------|---------------|----------------------|---------|-----------|
| WG-A | XXXX1         | m-server00 LAN10 IP  | 51820   | m-bastion |
| WG-B | XXXX2         | c-server00 LAN10 IP  | 51830   | c-bastion |

c-bastion uses listen port 51830 (not 51820) to avoid a NAT state conflict
on the Hitron CODA-4680 modem when both bastions share the same public IP.

Exact ports and IPs are in `site-A-secrets.env` and `site-B-secrets.env`
as `WG_PEER_ENDPOINT`.

---

## Google Nest configuration

The Google Nest connects to LAN10 (br-ext10, Google Home app -> Network -> DNS):
- Primary DNS: `10.x.10.1` (router00 LAN10 IP for that site)
- Secondary DNS: `8.8.8.8`

A static DHCP reservation is defined in `DHCP_STATIC_HOSTS` (site-*.env)
and written to `/etc/dnsmasq.d/static-dhcp.conf` on router00.

---

## Secret management

```sh
# Copy template for each site
cp site-specific-secrets.env.template site-A-secrets.env
cp site-specific-secrets.env.template site-B-secrets.env

# Generate WireGuard key pairs (one per site)
wg genkey | tee wg-A.key | wg pubkey > wg-A.pub
wg genkey | tee wg-B.key | wg pubkey > wg-B.pub

# Generate the lab SSH key
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_lab-maison-chalet -C "lab@lab"

# Fill in both secrets files:
#   WG_PRIVATE_KEY   -- this site's private key
#   WG_PEER_PUBKEY   -- the other site's public key
#   WG_PEER_ENDPOINT -- other site's public IP and UDP port
#   LAB_SSH_PUBKEY   -- content of id_ed25519_lab-maison-chalet.pub
#   LAB_PASSWORD, ROOT_PASSWORD
#   PRESEED_WIRELESS_ESSID, PRESEED_WIRELESS_WPA
```

`site-A-secrets.env` and `site-B-secrets.env` are in `.gitignore`.
Never commit them.

---

## End-to-end verification

```sh
# Inter-site traceroute
ssh c-demo-d-lan30 traceroute m-demo-d-lan5
# Expected path:
# 1  c-router00-vlan30    10.1.30.1
# 2  c-bastion-dmz        10.1.1.1
# 3  m-bastion-wg         10.0.0.1
# 4  m-router00-dmz       10.0.1.2
# 5  m-demo-d-lan5        10.0.5.x

# WireGuard handshake
ssh m-bastion sudo wg show
ssh c-bastion sudo wg show
# Expect: latest handshake within the last 25 seconds

# Infrastructure isolation: app VMs must not reach server00
ssh m-demo-d-lan30 ping -c 2 10.0.10.2   # must time out (LAN10 blocked)
ssh m-demo-d-lan10 ping -c 2 10.0.10.2   # must succeed  (LAN10 infra)

# Cross-site DNS
ssh m-router00 nslookup c-router00.chalet.lab
ssh c-router00 nslookup m-server00.maison.lab
```
