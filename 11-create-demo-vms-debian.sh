#!/bin/bash
# 11-create-demo-vms-debian.sh -- Deploy Debian 13 test VMs on LAN5, LAN10, VLAN20, VLAN30
#
# Prerequisite: run 04-download-update-debian-image.sh first to produce the
# patched base image (GRUB serial console, apt upgrade, baseline packages).
#
# Usage:
#   source site-A.env && source site-A-secrets.env && bash 11-create-demo-vms-debian.sh
#   source site-B.env && source site-B-secrets.env && bash 11-create-demo-vms-debian.sh
#
# Required env vars (from site-*.env + secrets-*.env):
#   SITE_NAME, DEMO_VM_PREFIX, DEMO_IP_PREFIX
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD
#   DEBIAN_EFFECTIVE_IMAGE_TO_USE
#
# MAC address generation:
#   Deterministic -- same site + VM name always produces the same MAC.
#   Algorithm: md5( "${SITE_NAME}::${VM_NAME}" ) -> bytes 0-3 -> prepend 52:54:
#   Example: maison::m-demo-d-lan10 -> 52:54:b0:65:42:f4  (always)

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------------------

for VAR in SITE_NAME DEMO_VM_PREFIX DEMO_IP_PREFIX LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD DEBIAN_EFFECTIVE_IMAGE_TO_USE; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "Usage: source site-A.env && source site-A-secrets.env && bash 11-create-demo-vms-debian.sh"
        exit 1
    fi
done

IMAGE_NAME="${DEBIAN_EFFECTIVE_IMAGE_TO_USE}"
IMAGE_PATH="/var/lib/libvirt/images/iso/${IMAGE_NAME}"

if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "ERROR: base image not found: ${IMAGE_PATH}"
    echo "       Run 04-download-update-debian-image.sh first."
    exit 1
fi

echo "==> Site: ${SITE_NAME}  prefix: ${DEMO_VM_PREFIX}  IP prefix: ${DEMO_IP_PREFIX}"
echo "==> Image: ${IMAGE_NAME}"
echo ""

# ------------------------------------------------------------------------------
# 1. Main loop -- one VM per LAN segment
# ------------------------------------------------------------------------------

for LAN_NUMBER in 5 10 20 30; do

    PORTGROUP=lan${LAN_NUMBER}
    VM_NAME=${DEMO_VM_PREFIX}-d-${PORTGROUP}      # 'd' stands for debian
    PSEUDO_IP=${DEMO_IP_PREFIX}.${LAN_NUMBER}.${LAN_NUMBER}

    # Deterministic MAC: md5( "${SITE_NAME}::${VM_NAME}" ), first 4 bytes
    HASH=$(echo -n "${SITE_NAME}::${VM_NAME}" | md5sum | awk '{print $1}')
    MAC_ADDRESS="52:54:${HASH:0:2}:${HASH:2:2}:${HASH:4:2}:${HASH:6:2}"

    # libvirt network selection
    if [[ "${LAN_NUMBER}" = "5" ]]; then
        NETWORK=lan-ext5
    elif [[ "${LAN_NUMBER}" = "10" ]]; then
        NETWORK=lan-ext10
    else
        NETWORK=lan-int
    fi

    echo "==> ${VM_NAME}  MAC=${MAC_ADDRESS}  IP-hint=${PSEUDO_IP}  NET=${NETWORK}/${PORTGROUP}"

    # --------------------------------------------------------------------------
    # 2. cloud-init: meta-data
    # --------------------------------------------------------------------------

    CIDATA=/tmp/${VM_NAME}-cidata
    mkdir -p "${CIDATA}"

    cat > "${CIDATA}/meta-data" << EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    # --------------------------------------------------------------------------
    # 3. cloud-init: user-data
    # --------------------------------------------------------------------------

    cat > "${CIDATA}/user-data.yaml" << EOF
#cloud-config
hostname: ${VM_NAME}
timezone: America/Montreal

ssh_pwauth: true

packages:
  - qemu-guest-agent
  - tcpdump
  - curl
  - bind9-dnsutils
  - htop
  - iputils-ping
  - netcat-openbsd

users:
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${LAB_SSH_PUBKEY}

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
  - path: /etc/motd
    content: |
      ================================================================================
        DEMO CLIENT (Debian 13) - NODE: ${VM_NAME}
      ================================================================================
        Network: ${NETWORK} | Portgroup: ${PORTGROUP} | IP hint: ${PSEUDO_IP}

        QUICK CONNECTIVITY TESTS:
        -------------------------
        1. Local IP    : ip -4 a show eth0
        2. Gateway     : ping -c 3 ${DEMO_IP_PREFIX}.${LAN_NUMBER}.1
        3. Internet    : ping -c 3 8.8.8.8
        4. DNS         : nslookup google.com

        SYSTEM:
        -------
        - Services     : systemctl list-units --state=running
        - Guest Agent  : systemctl status qemu-guest-agent
        - Routing      : ip route show

        NOTE: cloud-init is disabled after first boot. Use sudo for root tasks.
      ================================================================================

  - path: /etc/sysctl.d/99-disable-ipv6.conf
    content: |
      net.ipv6.conf.all.disable_ipv6 = 1
      net.ipv6.conf.default.disable_ipv6 = 1
      net.ipv6.conf.lo.disable_ipv6 = 1

  # systemd-networkd does not forward DHCP option 119 (domain search list)
  # to systemd-resolved by default. This drop-in enables it so that
  # short hostnames like m-demo-d-lan20 resolve without a FQDN.
  - path: /etc/systemd/network/10-dhcp.network
    content: |
      [Match]
      Name=en*

      [Network]
      DHCP=ipv4

      [DHCP]
      UseDNS=yes
      UseDomains=yes

runcmd:
  - sysctl -w net.ipv6.conf.all.disable_ipv6=1
  - sysctl -w net.ipv6.conf.default.disable_ipv6=1
  - systemctl enable qemu-guest-agent
  - systemctl start  qemu-guest-agent
  - systemctl restart systemd-networkd
  - touch /etc/cloud/cloud-init.disabled
  - reboot
EOF

    # --------------------------------------------------------------------------
    # 4. Destroy any existing VM, then deploy fresh
    # --------------------------------------------------------------------------

    sudo virsh destroy  "${VM_NAME}" 2>/dev/null || true
    sudo virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null || true

    # Build the cidata ISO with Rock Ridge extensions (-R) so that cloud-init
    # sees the correct long filenames "user-data" and "meta-data".
    # cloud-localds without -R produces 8.3 truncated names (USER_DAT, META_DAT)
    # which cloud-init does not recognize.
    cp "${CIDATA}/user-data.yaml" "${CIDATA}/user-data"
    sudo genisoimage \
        -output "/var/lib/libvirt/images/${VM_NAME}-cidata.iso" \
        -volid cidata \
        -joliet -rock \
        "${CIDATA}/user-data" \
        "${CIDATA}/meta-data"

    sudo cp "${IMAGE_PATH}" "/var/lib/libvirt/images/${VM_NAME}.qcow2"

    # Expand to 6G -- safe because 03c already grew the base image to 4G
    # and virt-resize rewrote the partition table. qemu-img resize only
    # extends the qcow2 virtual size; the partition uses the full space
    # on first boot via cloud-init growpart/resize2fs.
    sudo qemu-img resize "/var/lib/libvirt/images/${VM_NAME}.qcow2" 6G

    virt-install \
        --name "${VM_NAME}" \
        --memory 256 \
        --vcpus 1 \
        --os-variant debian13 \
        --disk "path=/var/lib/libvirt/images/${VM_NAME}.qcow2,format=qcow2" \
        --disk "path=/var/lib/libvirt/images/${VM_NAME}-cidata.iso,device=cdrom" \
        --network "network=${NETWORK},portgroup=${PORTGROUP},mac=${MAC_ADDRESS}" \
        --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
        --graphics none \
        --serial pty \
        --console pty,target_type=serial \
        --import \
        --noautoconsole

    virsh autostart "${VM_NAME}"

    echo "==> ${VM_NAME} launched (cloud-init reboot in ~60s)"
    echo "    Console : virsh console ${VM_NAME}  (Ctrl-] to exit)"
    echo "    MAC     : ${MAC_ADDRESS}"
    echo ""

done

echo "==> All Debian 13 demo VMs for ${SITE_NAME} launched"
echo ""
sudo virsh list
