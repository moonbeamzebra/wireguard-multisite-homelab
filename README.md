# WireGuard Lab -- Infrastructure as Code

Multi-site home lab running on VMware Fusion (Mac Intel) with two sites
connected by a WireGuard VPN tunnel. Simulates a real dual-site infrastructure
(primary residence + secondary residence) with full inter-site routing,
VLAN segmentation, and DNS.

## Architecture

```
Mac Intel (VMware Fusion host)
|
|-- jmp00 (Alpine VMware VM -- permanent bootstrap infrastructure)
|   eth0: Bridged WiFi  192.168.86.231   -> internet via Mac Wi-Fi
|   eth1: vmnet6        10.0.10.254      -> site home LAN
|   eth2: vmnet7        10.1.10.254      -> site cottage LAN
|   roles:
|     - Bootstrap internet gateway during host rebuild (before router00 exists)
|     - SSH ProxyJump entry point from Mac into both sites
|     - dnsmasq: resolves home.lab -> site A router00, cottage.lab -> site B
|     - iptables DROP eth1<->eth2: inter-site traffic forced via WireGuard
|
|-- Site home VM (Debian 12 / KVM / OVS)   hostname: h-server00
|   br-ext:        10.0.10.2/24   (vmnet6  -- LAN)
|   br-isp:        no IP          (vmnet3  -- passthrough to h-bastion eth0)
|   br-mgmt-access: no IP         (bridged -- Mac management access)
|   br-dmz:        no IP          (virtual segment h-bastion <-> h-router00)
|   ovs-lab:       no IP          (OVS trunk -- VLANs 20, 30)
|   |
|   |-- h-bastion (Alpine + WireGuard)
|   |   eth0 WAN: 192.168.0.10     -> h-ce -> internet
|   |   eth1 DMZ: 10.0.1.1/30
|   |   wg0:      10.0.0.1/30     <---- WireGuard tunnel ---->
|   |
|   |-- h-router00 (Alpine -- DHCP/DNS/inter-VLAN routing)
|   |   eth0 DMZ:   10.0.1.2/30
|   |   eth1 LAN10: 10.0.10.1
|   |   VLAN20:     10.0.20.1
|   |   VLAN30:     10.0.30.1
|   |
|   \-- h-demo-lan10/20/30 (Alpine -- test VMs)
|
\-- Site cottage VM (Debian 12 / KVM / OVS)   hostname: c-server00
    br-ext:        10.1.10.2/24   (vmnet7  -- LAN)
    br-isp:        no IP          (vmnet10 -- passthrough to c-bastion eth0)
    br-mgmt-access: no IP         (bridged -- Mac management access)
    br-dmz:        no IP          (virtual segment c-bastion <-> c-router00)
    ovs-lab:       no IP          (OVS trunk -- VLANs 20, 30)
    |
    |-- c-bastion (Alpine + WireGuard)
    |   eth0 WAN: 192.168.1.10     -> c-ce -> internet
    |   eth1 DMZ: 10.1.1.1/30
    |   wg0:      10.0.0.2/30     <---- WireGuard tunnel ---->
    |
    |-- c-router00 (Alpine -- DHCP/DNS/inter-VLAN routing)
    |   eth0 DMZ:   10.1.1.2/30
    |   eth1 LAN10: 10.1.10.1
    |   VLAN20:     10.1.20.1
    |   VLAN30:     10.1.30.1
    |
    \-- c-demo-lan10/20/30 (Alpine -- test VMs)
```

---

## VMware Fusion network configuration (Mac Intel)

These vmnet assignments are fixed in VMware Fusion preferences.
No DHCP, no NAT on any of these -- all static, all controlled by the lab:

```
vmnet3   192.168.0.0/24   site home ISP-side LAN   (h-ce LAN, h-bastion eth0)
vmnet6   10.0.10.0/24     site home internal LAN    (h-server00 br-ext, jmp00 eth1)
vmnet7   10.1.10.0/24     site cottage internal LAN (c-server00 br-ext, jmp00 eth2)
vmnet8   192.168.16.0/24  VMware NAT (Mac internet) (h-ce WAN, c-ce WAN)
vmnet10  192.168.1.0/24   site cottage ISP-side LAN (c-ce LAN, c-bastion eth0)
vmnet11  --               Bridged Wi-Fi (physical)  (jmp00 eth0, h-server00 br-mgmt-access)
```

Physical Wi-Fi (vmnet11 / bridged) is used by jmp00 for internet access and
by the server VMs for management access from the Mac. It has no fixed subnet
assignment -- it inherits whatever the Mac's Wi-Fi network provides.

---

## Naming conventions

All VM hostnames follow the pattern `${SITE_LETTER}-<role>`:

| Component        | Site home  | Site cottage | Notes                        |
|------------------|------------|--------------|------------------------------|
| Debian KVM host  | h-server00 | c-server00   | Set in preseed + 04-network  |
| ISP CE router    | h-ce       | c-ce         | OpenWRT, manual config       |
| WireGuard bastion| h-bastion  | c-bastion    |                              |
| DHCP/DNS router  | h-router00 | c-router00   |                              |
| Test VMs         | h-demo-lan10/20/30 | c-demo-lan10/20/30 |               |
| Bootstrap VM     | jmp00      | jmp00        | Single VM, serves both sites |

The naming is flexible -- site names (home, cottage) and the letter prefix
(h, c) are just variables in the env files. They can be anything you want
(e.g. bird names, city names) as long as they are consistent within the env.

---

## Images in use

There are two base images, each downloaded once and then prepared locally.

### 1. Debian 12 netinst ISO

Used to install the KVM host (Debian bare metal inside a VMware VM).

```
Source: https://cdimage.debian.org/cdimage/archive/12.10.0/amd64/iso-cd/
File:   debian-12.10.0-amd64-netinst.iso
```

Manipulated by `02-create-server00.sh` (runs on the Mac Intel):
- Downloaded automatically if not present
- Preseed config generated from `preseed.cfg.tmpl` + site env + secrets
- Boot loader patched: text installer set as default, preseed auto-selected
- Repackaged as `debian-12-preseed-home.iso` / `debian-12-preseed-cottage.iso`

Attach to the VMware host VM for a fully automated Debian install.
Detach after first reboot.

### 2. Alpine cloud-init (NoCloud) image

Used for all KVMs and for jmp00 (VMware).

```
Source: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/
File:   nocloud_alpine-3.23.3-x86_64-bios-cloudinit-r0.qcow2
```

**Step A -- update-alpine-image.sh** (run on a KVM host, repeat periodically):
- Copies original -> `...-updated.qcow2`
- Expands image filesystem by +500M
- Mounts via guestfish and runs `apk update && apk upgrade` inside
- Clears cloud-init instance state
- Result stored in `/var/lib/libvirt/images/iso/`
- scp the result to the other site host to keep both in sync

**Step B -- KVM deployment** (07-create-bastion.sh, 08-create-router00.sh, 09-create-demo-vms.sh):
- Copies `...-updated.qcow2` -> `/var/lib/libvirt/images/<vm>.qcow2`
- Resizes the copy to 6G
- Generates a cidata ISO (meta-data + user-data) with cloud-init config
- `virt-install` boots the VM with both the disk and the cidata ISO
- VM reboots once after cloud-init, then operational

**Step C -- jmp00 (01-create-jmp00.sh)** (run on the Mac Intel):
- Ensures the updated image exists (downloads + runs update-alpine-image.sh if not)
- Copies and resizes to 6G
- Converts qcow2 -> VMDK (`qemu-img convert -O vmdk`)
- Generates the cidata ISO with full jmp00 config (dnsmasq, iptables, routes)
- Starts the VMware VM automatically with vmrun
- Requires: brew install qemu (for qemu-img); hdiutil is macOS built-in

---

## File structure

```
.
|-- site-A.env                  # Site A (home) public config     [git-tracked]
|-- site-B.env                  # Site B (cottage) public config  [git-tracked]
|-- secrets-A.env               # Site A secrets                  [gitignored]
|-- secrets-B.env               # Site B secrets                  [gitignored]
|-- secrets-A.env.template      # Template -- copy and fill in
|-- secrets-B.env.template
|-- .gitignore
|
|-- preseed.cfg.tmpl            # Debian preseed template (%%PLACEHOLDERS%%)
|-- 02-create-server00.sh         # Mac: builds site-specific preseed ISO
|-- 01-create-jmp00.sh           # Mac Intel: fully automated jmp00 VM creation
|-- update-alpine-image.sh      # Host: updates the shared Alpine base image
|
|-- 03-packages.sh              # Host: install KVM/OVS/libvirt packages
|-- 04-network.sh               # Host: configure OVS + netplan bridges
|-- 05-libvirt-nets.sh          # Host: define libvirt networks
|-- 06-libvirt-config.sh        # Host: libvirt-guests suspend/resume on host reboot
|
|-- 07-create-bastion.sh           # KVM: WireGuard bastion (h-bastion / c-bastion)
|-- 08-create-router00.sh                 # KVM: DHCP/DNS/routing (h-router00 / c-router00)
|-- 09-create-demo-vms.sh                 # KVM: test VMs on LAN10, VLAN20, VLAN30
|
\-- ce-notes.md                 # OpenWRT CE router manual setup notes
```

---

## Secret management

1. Copy the templates:
   ```
   cp secrets-A.env.template secrets-A.env
   cp secrets-B.env.template secrets-B.env
   ```

2. Generate WireGuard keys:
   ```
   wg genkey | tee wg-A.key | wg pubkey > wg-A.pub
   wg genkey | tee wg-B.key | wg pubkey > wg-B.pub
   ```
   - secrets-A.env: site-A private key + site-B public key + site-B CE endpoint
   - secrets-B.env: site-B private key + site-A public key + site-A CE endpoint
   WG_PEER_ENDPOINT (the remote CE public IP and port) is in secrets, not
   in site-*.env, to avoid publishing your ISP addresses and WireGuard port.

3. Generate the lab SSH key:
   ```
   ssh-keygen -t ed25519 -f ~/.ssh/lab_ed25519 -C "lab@lab"
   ```
   Put the public key into LAB_SSH_PUBKEY in both secrets files.

4. secrets-*.env is in .gitignore -- never commit these files.

---

## Deployment workflow

### Phase 0 -- jmp00 (VMware -- do once, keep running forever)

jmp00 must exist before anything else. It is your bootstrap gateway
(provides internet to hosts during rebuild) and permanent SSH entry
point into both sites.

Run entirely on the Mac Intel -- no Linux host needed:

```
# One-time prerequisite:
brew install qemu           # provides qemu-img

# Then:
source secrets-A.env        # or secrets-B.env -- same keys for both
bash 01-create-jmp00.sh
```

The script (runs on Linux host):
- Uses the --updated Alpine image (runs update-alpine-image.sh if missing)
- Resizes to 6G, converts to VMDK, generates cidata ISO and VMX
- Outputs to /tmp/jmp00-build/

Then scp the bundle to the Mac and start with vmrun:
```
MAC_VM_DIR="$HOME/VirtualMachines/jmp00-lab.vmwarevm"
scp -r /tmp/jmp00-build/ <mac-user>@<mac-ip>:"$MAC_VM_DIR"

VMLIB="/Applications/VMware Fusion.app/Contents/Library"
"$VMLIB/vmrun" -T fusion start "$MAC_VM_DIR/jmp00-lab.vmx" nogui
```

Boot takes ~60s (cloud-init + one reboot). Detach the cidata ISO after.

Note: once macOS is upgraded to Monterey and qemu-img is available via brew,
01-create-jmp00.sh can be ported to run directly on the Mac.

Add to ~/.ssh/config on your Mac (M2):
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

### Phase 1 -- Preseed ISO (Mac Intel -- per site, as needed)

```
# Source the site env + secrets, then:
source site-A.env && source secrets-A.env
bash 02-create-server00.sh
# Script generates the preseed ISO.
# -> debian-12-preseed-home.iso
```

During install and the 03-packages.sh phase, internet goes via jmp00.
Set in the site env before running 02-create-server00.sh:
```
export PRESEED_GW=10.0.10.254   # site home -- jmp00 as bootstrap gateway
export PRESEED_GW=10.1.10.254   # site cottage
```
After 04-network.sh is done and router00 is deployed, restore:
```
export PRESEED_GW=${GW_BR_EXT}  # back to router00 (10.x.10.1)
```

### Phase 2 -- VMware host VM

Create the VM manually in VMware Fusion:
- OS: Debian 12 64-bit    Disk: 100G    RAM: 6G    CPU: 2
- Adapter 1: VNET_LAN  (vmnet6 site A / vmnet7 site B)   -> LAN
- Adapter 2: VNET_ISP  (vmnet3 site A / vmnet10 site B)  -> ISP
- Adapter 3: VNET_MGMT (vmnet11 bridged Wi-Fi)           -> management
- Attach the preseed ISO as CD/DVD
- Boot -- fully automated install (~10 min), detach ISO after reboot

### Phase 3 -- Host setup

```
# scp scripts to the host, then:
sudo bash 03-packages.sh

source site-A.env && source secrets-A.env
sudo -E bash 04-network.sh
sudo netplan apply
# The IP does not change (set by preseed). Session should survive.
# ping GW and ping 8.8.8.8 will fail here -- router00 not yet deployed.
# Internet for apt-get during 03-packages.sh worked via jmp00 (PRESEED_GW).

sudo bash 05-libvirt-nets.sh
sudo bash 06-libvirt-config.sh
```

### Phase 4 -- KVMs

```
source site-A.env && source secrets-A.env

bash 07-create-bastion.sh   # h-bastion: WireGuard + internet gateway
bash 08-create-router00.sh         # h-router00: DHCP + DNS + inter-VLAN routing
bash 09-create-demo-vms.sh         # h-demo-lan10/20/30: test VMs
```

### Phase 5 -- CE router (OpenWRT, manual)

See ce-notes.md.

---

## End-to-end sanity checks

```
# From Mac (via jmp00 ProxyJump):
ssh h-demo-lan30.home.lab traceroute c-demo-lan30.cottage.lab

# Expected path:
#   1  h-router00-vlan30.home.lab    10.0.30.1
#   2  h-bastion-dmz.home.lab        10.0.1.1
#   3  c-bastion-wg.cottage.lab      10.0.0.2
#   4  c-router00-dmz.cottage.lab    10.1.1.2
#   5  c-demo-lan30.cottage.lab      10.1.30.x

# WireGuard status on bastion:
ssh h-bastion.home.lab sudo wg show

# Inter-site DNS:
ssh h-router00.home.lab nslookup c-router00.cottage.lab
ssh c-router00.cottage.lab nslookup h-router00.home.lab

# jmp00 DNS (dnsmasq split-horizon):
ssh jmp00 nslookup h-router00.home.lab
ssh jmp00 nslookup c-router00.cottage.lab
```

---

## Adding a third site

1. Copy site-A.env -> site-C.env, adjust all IPs, SITE_NAME, SITE_LETTER, domains.
2. Copy secrets-A.env.template -> secrets-C.env.template, fill in WireGuard keys.
3. All scripts are site-agnostic: source site-C.env && source secrets-C.env
   is all that is needed before any script.
4. Update DNS_STATIC, DNS_REMOTE_DOMAIN, DNS_REMOTE_SERVER in existing site
   env files to forward the new site domain.
5. Add a peer block in the new site bastion and in both existing bastions.
6. Add a server= line in jmp00's dnsmasq.conf for the new site domain,
   then re-run 01-create-jmp00.sh and redeploy jmp00.
