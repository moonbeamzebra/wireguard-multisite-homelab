#!/bin/bash
# 01-create-jmp00.sh -- Build jmp00 VMDK + cloud-init ISO
# Run on: LINUX HOST (site A or B)
#
# jmp00 is a permanent VMware VM (Alpine) with 3 interfaces:
#   eth0 -- Bridged WiFi (vmnet11)      192.168.86.231  internet
#   eth1 -- vmnet6 (10.0.10.0/24)       10.0.10.254     site home LAN
#   eth2 -- vmnet7 (10.1.10.0/24)       10.1.10.254     site cottage LAN
#
# Roles:
#   - Bootstrap internet gateway during host rebuild (PRESEED_GW points here)
#   - SSH ProxyJump entry point from Mac for both sites
#   - dnsmasq: split-horizon DNS (home.lab -> site A, cottage.lab -> site B)
#   - iptables MASQUERADE on eth0 for bootstrap internet
#   - iptables DROP eth1<->eth2: inter-site must go via WireGuard
#
# Produces:
#   /tmp/jmp00-build/jmp00.vmdk
#   /tmp/jmp00-build/jmp00-cidata.iso
#   /tmp/jmp00-build/jmp00-lab.vmx
#
# After this script:
#   scp -r /tmp/jmp00-build/ <mac-user>@<mac-ip>:~/VirtualMachines/jmp00-lab.vmwarevm/
#   Then on the Mac Intel:
#   "/Applications/VMware Fusion.app/Contents/Library/vmrun" \
#       -T fusion start ~/VirtualMachines/jmp00-lab.vmwarevm/jmp00-lab.vmx nogui
#
# Note: When qemu-img becomes available on the Mac (after macOS upgrade),
# this script can be ported to run natively on the Mac Intel -- the logic
# is identical, only cloud-localds is replaced by hdiutil.
#
# Prerequisites (installed by 03-packages.sh on the Linux host):
#   qemu-utils         (qemu-img)
#   cloud-image-utils  (cloud-localds)
#
# Required env vars (from secrets-A.env or secrets-B.env -- same for both):
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD

set -euo pipefail

for VAR in LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD VNET_JMP_ETH0 VNET_JMP_ETH1 VNET_JMP_ETH2; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "Usage: source secrets-A.env && bash 01-create-jmp00.sh"
        exit 1
    fi
done

# ------------------------------------------------------------------
# Image paths
# ------------------------------------------------------------------
IMAGE_DIR="/var/lib/libvirt/images/iso"
IMAGE_UPDATED="${IMAGE_DIR}/nocloud_alpine-3.23.3-x86_64-bios-cloudinit-r0--updated.qcow2"
IMAGE_ORIGINAL="${IMAGE_DIR}/nocloud_alpine-3.23.3-x86_64-bios-cloudinit-r0.qcow2"
ALPINE_DOWNLOAD_URL="https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.3-x86_64-bios-cloudinit-r0.qcow2"

VM_NAME=jmp00-lab
BUILD_DIR="/tmp/jmp00-build"
VMDK_OUT="${BUILD_DIR}/jmp00.vmdk"
ISO_OUT="${BUILD_DIR}/jmp00-cidata.iso"
VMX_OUT="${BUILD_DIR}/${VM_NAME}.vmx"
CIDATA_DIR="/tmp/jmp00-cidata"

mkdir -p "${BUILD_DIR}" "${CIDATA_DIR}"

# ------------------------------------------------------------------
# Step 1 -- Ensure the updated Alpine image exists
# ------------------------------------------------------------------
echo "=== Step 1: Alpine --updated image ==="

if [[ ! -f "${IMAGE_UPDATED}" ]]; then
    echo "--- Updated image not found: ${IMAGE_UPDATED}"
    if [[ ! -f "${IMAGE_ORIGINAL}" ]]; then
        echo "--- Downloading original image..."
        sudo mkdir -p "${IMAGE_DIR}"
        sudo curl -L -o "${IMAGE_ORIGINAL}" "${ALPINE_DOWNLOAD_URL}"
    fi
    echo "--- Running update-alpine-image.sh..."
    bash "$(dirname "$0")/update-alpine-image.sh"
fi

echo "--- Source: ${IMAGE_UPDATED}"
qemu-img info "${IMAGE_UPDATED}" | grep -E "^(file format|virtual size|disk size)"

# ------------------------------------------------------------------
# Step 2 -- Copy and resize to 6G
# ------------------------------------------------------------------
echo ""
echo "=== Step 2: Copy and resize to 6G ==="

WORK_QCOW="${BUILD_DIR}/jmp00-work.qcow2"
cp "${IMAGE_UPDATED}" "${WORK_QCOW}"
qemu-img resize "${WORK_QCOW}" 6G
echo "--- Resized to 6G"

# ------------------------------------------------------------------
# Step 3 -- Convert to VMDK
# ------------------------------------------------------------------
echo ""
echo "=== Step 3: Convert qcow2 -> VMDK ==="

qemu-img convert -f qcow2 -O vmdk "${WORK_QCOW}" "${VMDK_OUT}"
rm -f "${WORK_QCOW}"
echo "--- VMDK: ${VMDK_OUT}"
qemu-img info "${VMDK_OUT}" | grep -E "^(file format|virtual size|disk size)"

# ------------------------------------------------------------------
# Step 4 -- Generate cloud-init ISO
# ------------------------------------------------------------------
echo ""
echo "=== Step 4: cloud-init ISO ==="

cat > "${CIDATA_DIR}/meta-data" << EOF
instance-id: jmp00
local-hostname: jmp00
EOF

cat > "${CIDATA_DIR}/user-data" << EOF
#cloud-config
hostname: jmp00
timezone: America/Montreal

ssh_pwauth: false

network:
  config: disabled

# dnsmasq manages DNS -- resolv.conf written in runcmd
# manage_resolv_conf disabled so cloud-init does not overwrite it
manage_resolv_conf: false

packages:
  - sudo
  - htop
  - iptables
  - iptables-openrc
  - dnsmasq
  - e2fsprogs

users:
  - name: lab
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/ash
    # TODO: remove lock_passwd once stable
    lock_passwd: false
    ssh_authorized_keys:
      - ${LAB_SSH_PUBKEY}

# TODO: remove chpasswd block once stable
chpasswd:
  expire: false
  users:
    - name: root
      password: ${ROOT_PASSWORD}
      type: text
    - name: lab
      password: ${LAB_PASSWORD}
      type: text

write_files:

  # -- Static network interfaces ------------------------------------------
  # eth0 -- vmnet11 Bridged WiFi  192.168.86.231/24  GW 192.168.86.1
  # eth1 -- vmnet6                10.0.10.254/24     site home LAN
  # eth2 -- vmnet7                10.1.10.254/24     site cottage LAN
  #
  # post-up routes fail gracefully (|| true) when router00 is not yet
  # deployed -- during bootstrap the host only needs internet via eth0.
  - path: /etc/network/interfaces
    content: |
      auto lo
      iface lo inet loopback

      auto eth0
      iface eth0 inet static
          address 192.168.86.231
          netmask 255.255.255.0
          gateway 192.168.86.1

      auto eth1
      iface eth1 inet static
          address 10.0.10.254
          netmask 255.255.255.0
          post-up ip route add 10.0.0.0/16 via 10.0.10.1 dev eth1 || true
          pre-down ip route del 10.0.0.0/16 via 10.0.10.1 dev eth1 || true

      auto eth2
      iface eth2 inet static
          address 10.1.10.254
          netmask 255.255.255.0
          post-up ip route add 10.1.0.0/16 via 10.1.10.1 dev eth2 || true
          pre-down ip route del 10.1.0.0/16 via 10.1.10.1 dev eth2 || true

  # -- /etc/hosts -- bootstrap name resolution ----------------------------
  - path: /etc/hosts
    content: |
      127.0.0.1   localhost
      ::1         localhost
      10.0.10.2   h-server00 h-server00.home.lab
      10.1.10.2   c-server00 c-server00.cottage.lab

  # -- dhcpcd.conf -- prevent DHCP from overwriting resolv.conf ----------
  # dhcpcd runs by default on Alpine and would overwrite /etc/resolv.conf
  # with whatever the DHCP server on eth0 provides, discarding our dnsmasq
  # setup. These static overrides force dhcpcd to always use 127.0.0.1
  # and our search domains regardless of DHCP response.
  - path: /etc/dhcpcd.conf
    append: true
    content: |
      static domain_search=home.lab cottage.lab
      static domain_name_servers=127.0.0.1

  # -- dnsmasq -- split-horizon DNS ---------------------------------------
  # no-resolv: ignore /etc/resolv.conf upstream entries, use server= only
  # home.lab    -> h-router00 (10.0.10.1)
  # cottage.lab -> c-router00 (10.1.10.1)
  # Reverse PTR zones follow the same split
  # Internet DNS: 192.168.86.1 (bridged Wi-Fi GW)
  - path: /etc/dnsmasq.conf
    content: |
      no-resolv
      server=192.168.86.1
      server=/home.lab/10.0.10.1
      server=/cottage.lab/10.1.10.1
      server=/0.10.in-addr.arpa/10.0.10.1
      server=/1.10.in-addr.arpa/10.1.10.1

  # -- sysctl: ip_forward -------------------------------------------------
  - path: /etc/sysctl.d/10-jmp00.conf
    content: |
      net.ipv4.ip_forward=1

  # -- iptables -----------------------------------------------------------
  # NAT:
  #   MASQUERADE on eth0: site hosts use jmp00 as internet gateway during
  #   bootstrap (PRESEED_GW=10.x.10.254). Once bastion is deployed,
  #   normal internet goes via bastion/CE; this only activates for hosts
  #   still pointing at jmp00.
  #
  # FORWARD:
  #   eth1/eth2 -> eth0: bootstrap internet gateway
  #   eth1 <-> eth2:     BLOCKED -- inter-site goes via WireGuard only
  #
  # INPUT:
  #   SSH and ICMP on all interfaces, everything else DROP
  - path: /etc/iptables/rules-save
    content: |
      *nat
      :PREROUTING ACCEPT [0:0]
      :INPUT ACCEPT [0:0]
      :OUTPUT ACCEPT [0:0]
      :POSTROUTING ACCEPT [0:0]
      -A POSTROUTING -o eth0 -j MASQUERADE
      COMMIT

      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]

      -A INPUT -i lo -j ACCEPT
      -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      -A INPUT -i eth0 -p tcp --dport 22 -j ACCEPT
      -A INPUT -i eth1 -p tcp --dport 22 -j ACCEPT
      -A INPUT -i eth2 -p tcp --dport 22 -j ACCEPT
      -A INPUT -p icmp -j ACCEPT

      -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
      -A FORWARD -i eth1 -o eth0 -j ACCEPT
      -A FORWARD -i eth2 -o eth0 -j ACCEPT
      -A FORWARD -i eth0 -o eth1 -j ACCEPT
      -A FORWARD -i eth0 -o eth2 -j ACCEPT
      -A FORWARD -i eth1 -o eth2 -j DROP
      -A FORWARD -i eth2 -o eth1 -j DROP

      COMMIT

  # -- SSH: agent and TCP forwarding for ProxyJump ------------------------
  - path: /etc/ssh/sshd_config.d/jmp00.conf
    content: |
      Match User lab
          AllowTcpForwarding yes
          AllowAgentForwarding yes

runcmd:
  # Expand ext4 filesystem to use the full 6G disk.
  # qemu-img resize enlarges the virtual disk but not the filesystem inside.
  # The --updated image has ext4 on /dev/sda; resize2fs claims the space.
  - e2fsck -f /dev/sda || true
  - resize2fs /dev/sda || true

  - rc-update add networking boot
  - rc-service networking restart
  - sysctl -p /etc/sysctl.d/10-jmp00.conf

  # Set resolv.conf to point at local dnsmasq
  - echo "search home.lab cottage.lab" > /etc/resolv.conf
  - echo "nameserver 127.0.0.1" >> /etc/resolv.conf

  # Force iptables-legacy (virtualised kernel may lack nf_tables)
  - ln -sf /sbin/iptables-legacy         /sbin/iptables
  - ln -sf /sbin/iptables-legacy-restore /sbin/iptables-restore
  - ln -sf /sbin/iptables-legacy-save    /sbin/iptables-save
  - rc-update add iptables default
  - /etc/init.d/iptables start

  - rc-update add dnsmasq default
  - rc-service dnsmasq start

  - touch /etc/cloud/cloud-init.disabled
  - rc-update del cloud-init default 2>/dev/null || true
  - rc-update del cloud-config default 2>/dev/null || true
  - rc-update del cloud-final default 2>/dev/null || true
  - reboot
EOF

cloud-localds "${ISO_OUT}" \
    "${CIDATA_DIR}/user-data" \
    "${CIDATA_DIR}/meta-data"

echo "--- ISO: ${ISO_OUT}"

# ------------------------------------------------------------------
# Step 5 -- Generate VMX config
# ------------------------------------------------------------------
echo ""
echo "=== Step 5: VMX ==="

# ethernet0: vmnet11 (Bridged Wi-Fi) -- eth0 internet
# ethernet1: vmnet6                  -- eth1 site home LAN
# ethernet2: vmnet7                  -- eth2 site cottage LAN
cat > "${VMX_OUT}" << VMXEOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "16"
displayName = "jmp00-lab"
guestOS = "other5xlinux-64"
nvram = "jmp00-lab.nvram"
virtualHW.productCompatibility = "hosted"
powerType.powerOff = "soft"
powerType.powerOn = "soft"
powerType.suspend = "soft"
powerType.reset = "soft"
memsize = "256"
numvcpus = "1"
scsi0.virtualDev = "lsilogic"
scsi0.present = "TRUE"
scsi0:0.fileName = "jmp00.vmdk"
scsi0:0.present = "TRUE"
ide1:0.deviceType = "cdrom-image"
ide1:0.fileName = "jmp00-cidata.iso"
ide1:0.present = "TRUE"
floppy0.present = "FALSE"
usb.present = "TRUE"
ehci.present = "TRUE"
sound.present = "FALSE"
serial0.present = "FALSE"
ethernet0.present = "TRUE"
ethernet0.connectionType = "custom"
ethernet0.virtualDev = "e1000"
ethernet0.addressType = "generated"
ethernet0.vnet = "${VNET_JMP_ETH0}"
ethernet0.bsdName = "en0"
ethernet0.displayName = "Wi-Fi"
ethernet0.linkStatePropagation.enable = "TRUE"
ethernet1.present = "TRUE"
ethernet1.connectionType = "custom"
ethernet1.virtualDev = "e1000"
ethernet1.addressType = "generated"
ethernet1.vnet = "${VNET_JMP_ETH1}"
ethernet2.present = "TRUE"
ethernet2.connectionType = "custom"
ethernet2.virtualDev = "e1000"
ethernet2.addressType = "generated"
ethernet2.vnet = "${VNET_JMP_ETH2}"
tools.syncTime = "TRUE"
tools.upgrade.policy = "upgradeAtPowerCycle"
vhv.enable = "FALSE"
hpet0.present = "TRUE"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
vmci0.present = "TRUE"
extendedConfigFile = "jmp00-lab.vmxf"
VMXEOF

echo "--- VMX: ${VMX_OUT}"

# ------------------------------------------------------------------
# Step 6 -- Summary
# ------------------------------------------------------------------
echo ""
echo "=== Done ==="
echo ""
echo "Output bundle: ${BUILD_DIR}/"
ls -lh "${BUILD_DIR}/"
echo ""
echo "Copy to Mac Intel and start:"
echo ""
echo "  MAC_VM_DIR=\"\$HOME/VirtualMachines/jmp00-lab.vmwarevm\""
echo "  scp -r ${BUILD_DIR}/ <mac-user>@<mac-ip>:\"\$MAC_VM_DIR\""
echo ""
echo "  Then on the Mac Intel:"
echo "  VMRUN=\"/Applications/VMware Fusion.app/Contents/Library/vmrun\""
echo "  \"\$VMRUN\" -T fusion start \"\$MAC_VM_DIR/jmp00-lab.vmx\" nogui"
echo ""
echo "Boot: cloud-init runs then reboots once (~60s total)."
echo "Detach jmp00-cidata.iso from the VM after first boot."
echo ""
echo "Verify after reboot:"
echo "  ssh lab@192.168.86.231"
echo "  cat /etc/resolv.conf              -- should show nameserver 127.0.0.1"
echo "  ping 8.8.8.8                      -- internet"
echo "  nslookup h-server00.home.lab      -- dnsmasq -> 10.0.10.1 (once router00 up)"
echo "  nslookup c-server00.cottage.lab   -- dnsmasq -> 10.1.10.1"
echo "  sudo iptables -L FORWARD -n -v    -- check inter-site DROP"
echo ""
echo "~/.ssh/config on your Mac (M2):"
echo "  Host jmp00"
echo "      HostName 192.168.86.231"
echo "      User lab"
echo "      ForwardAgent yes"
echo ""
echo "  Host *.home.lab"
echo "      ProxyJump jmp00"
echo "      User lab"
echo ""
echo "  Host *.cottage.lab"
echo "      ProxyJump jmp00"
echo "      User lab"
