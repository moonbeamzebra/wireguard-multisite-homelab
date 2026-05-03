#!/bin/bash
# 09-create-demo-vms-alpine.sh -- Deploy Alpine test VMs on LAN5, LAN10, VLAN20, VLAN30
#
# Usage:
#   source site-A-GMKtec.env && source secrets-A-GMKtec.env && bash 09-create-demo-vms-alpine.sh
#   source site-B-GMKtec.env && source secrets-B-GMKtec.env && bash 09-create-demo-vms-alpine.sh
#
# Required env vars (from site-*.env + secrets-*.env):
#   SITE_NAME, DEMO_VM_PREFIX, DEMO_IP_PREFIX
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD
#   ALPINE_EFFECTIVE_IMAGE_TO_USE
#
# MAC address generation:
#   Deterministic -- same site + VM name always produces the same MAC.
#   Algorithm: md5( "${SITE_NAME}::${VM_NAME}" ) -> bytes 0-3 -> prepend 52:54:
#   Example: maison::m-demo-a-lan10 -> 52:54:xx:xx:xx:xx  (always)

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------------------

for VAR in SITE_NAME DEMO_VM_PREFIX DEMO_IP_PREFIX \
           LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD \
           ALPINE_EFFECTIVE_IMAGE_TO_USE; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "Usage: source site-A-GMKtec.env && source secrets-A-GMKtec.env && bash 09-create-demo-vms-alpine.sh"
        exit 1
    fi
done

IMAGE_NAME="${ALPINE_EFFECTIVE_IMAGE_TO_USE}"
IMAGE_PATH="/var/lib/libvirt/images/iso/${IMAGE_NAME}"

if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "ERROR: base image not found: ${IMAGE_PATH}"
    echo "       Run 03b-download-update-alpine-image.sh first."
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
    VM_NAME=${DEMO_VM_PREFIX}-a-${PORTGROUP}      # 'a' stands for alpine
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
  - sudo
  - htop
  - tcpdump
  - curl
  - bind-tools
  - netcat-openbsd

users:
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/ash
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
        DEMO CLIENT (Alpine) - NODE: ${VM_NAME}
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
        - Services     : rc-status -s
        - Guest Agent  : rc-service qemu-guest-agent status
        - Routing      : ip route show

        NOTE: cloud-init is disabled after first boot. Use sudo for root tasks.
      ================================================================================

runcmd:
  - apk add --no-cache qemu-guest-agent
  - rc-update add qemu-guest-agent default
  - rc-service qemu-guest-agent start

  # Disable IPv6
  - echo "noipv6" >> /etc/dhcpcd.conf
  - sed -i 's/default_kernel_opts="/default_kernel_opts="ipv6.disable=1 /' /etc/update-extlinux.conf
  - update-extlinux
  - sed -i 's/^net.ipv6/#net.ipv6/' /usr/lib/sysctl.d/00-alpine.conf

  # Disable cloud-init after first boot
  - touch /etc/cloud/cloud-init.disabled
  - rc-update del cloud-init   default 2>/dev/null || true
  - rc-update del cloud-config default 2>/dev/null || true
  - rc-update del cloud-final  default 2>/dev/null || true
  - reboot
EOF

    # --------------------------------------------------------------------------
    # 4. Destroy any existing VM, then deploy fresh
    # --------------------------------------------------------------------------

    sudo virsh destroy  "${VM_NAME}" 2>/dev/null || true
    sudo virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null || true

    sudo cloud-localds "/var/lib/libvirt/images/${VM_NAME}-cidata.iso" \
        "${CIDATA}/user-data.yaml" \
        "${CIDATA}/meta-data"

    sudo cp "${IMAGE_PATH}" "/var/lib/libvirt/images/${VM_NAME}.qcow2"
    sudo qemu-img resize "/var/lib/libvirt/images/${VM_NAME}.qcow2" 2G

    virt-install \
        --name "${VM_NAME}" \
        --memory 192 \
        --vcpus 1 \
        --os-variant alpinelinux3.21 \
        --disk "path=/var/lib/libvirt/images/${VM_NAME}.qcow2,format=qcow2" \
        --disk "path=/var/lib/libvirt/images/${VM_NAME}-cidata.iso,device=cdrom" \
        --network "network=${NETWORK},portgroup=${PORTGROUP},mac=${MAC_ADDRESS}" \
        --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
        --graphics none \
        --import \
        --noautoconsole

    virsh autostart "${VM_NAME}"

    echo "==> ${VM_NAME} launched (reboots after cloud-init, ~30s)"
    echo "    Console : virsh console ${VM_NAME}  (Ctrl-] to exit)"
    echo "    MAC     : ${MAC_ADDRESS}"
    echo ""

done

echo "==> All Alpine demo VMs for ${SITE_NAME} launched"
echo ""
sudo virsh list
