#!/bin/bash
# 09-create-demo-vms.sh -- Deploy test VMs on LAN10, VLAN20, VLAN30
#
# Usage:
#   source site-A.env && source secrets-A.env && bash 09-create-demo-vms.sh
#   source site-B.env && source secrets-B.env && bash 09-create-demo-vms.sh
#
# Required env vars (from site-*.env + secrets-*.env):
#   SITE_NAME, DEMO_VM_PREFIX, DEMO_IP_PREFIX
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD

set -euo pipefail

for VAR in SITE_NAME DEMO_VM_PREFIX DEMO_IP_PREFIX LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "Usage: source site-A.env && source secrets-A.env && bash 09-create-demo-vms.sh"
        exit 1
    fi
done

IMAGE_NAME=${ALPINE_EFFECTIVE_IMAGE_TO_USE}

echo "==> Site: ${SITE_NAME}  VM prefix: ${DEMO_VM_PREFIX}  IP prefix: ${DEMO_IP_PREFIX}"
echo ""

for LAN_NUMBER in 10 20 30; do

    PORTGROUP=lan${LAN_NUMBER}
    VM_NAME=${DEMO_VM_PREFIX}-${PORTGROUP}
    PSEUDO_IP=${DEMO_IP_PREFIX}.${LAN_NUMBER}.${LAN_NUMBER}
    MAC_ADDRESS=$(echo "${PSEUDO_IP}" | awk -F. '{printf "52:54:%02x:%02x:%02x:%02x\n", $1, $2, $3, $4}')

    if [[ "${LAN_NUMBER}" = "10" ]]; then
        NETWORK=lan-ext
    else
        NETWORK=lan-int
    fi

    echo "==> ${VM_NAME}  MAC=${MAC_ADDRESS}  NETWORK=${NETWORK}  PORTGROUP=${PORTGROUP}"

    CIDATA=/tmp/${VM_NAME}-cidata
    mkdir -p ${CIDATA}

    cat > ${CIDATA}/meta-data << EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    cat > ${CIDATA}/user-data.yaml << EOF
#cloud-config
hostname: ${VM_NAME}
timezone: America/Montreal

ssh_pwauth: true

packages:
  - sudo
  - htop

users:
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/ash
    ## TODO: remove lock_passwd once stable
    lock_passwd: false
    ssh_authorized_keys:
      - ${LAB_SSH_PUBKEY}

## TODO: remove chpasswd block once stable
chpasswd:
  expire: false
  users:
    - name: root
      password: ${ROOT_PASSWORD}
      type: text
    - name: lab
      password: ${LAB_PASSWORD}
      type: text

runcmd:
  - apk add --no-cache qemu-guest-agent
  - rc-update add qemu-guest-agent default

  # IPv6 Hardening
  - echo "noipv6" >> /etc/dhcpcd.conf
  # 1. Disable IPv6 at kernel level for next boots
  - sed -i 's/default_kernel_opts="/default_kernel_opts="ipv6.disable=1 /' /etc/update-extlinux.conf
  - update-extlinux

  # 2. Silence existing IPv6 sysctl errors by commenting them out
  - sed -i 's/^net.ipv6/#net.ipv6/' /usr/lib/sysctl.d/00-alpine.conf

  # 3. Clean up cloud-init and other services
  - touch /etc/cloud/cloud-init.disabled
  - rc-update del cloud-init default 2>/dev/null || true
  - rc-update del cloud-config default 2>/dev/null || true
  - rc-update del cloud-final default 2>/dev/null || true
  - reboot
EOF

    sudo virsh destroy ${VM_NAME} 2>/dev/null || true
    sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true

    sudo cloud-localds /var/lib/libvirt/images/${VM_NAME}-cidata.iso \
        ${CIDATA}/user-data.yaml \
        ${CIDATA}/meta-data

    sudo cp /var/lib/libvirt/images/iso/${IMAGE_NAME} \
            /var/lib/libvirt/images/${VM_NAME}.qcow2
    sudo qemu-img resize /var/lib/libvirt/images/${VM_NAME}.qcow2 6G

    virt-install \
        --name ${VM_NAME} \
        --memory 192 \
        --vcpus 1 \
        --os-variant alpinelinux3.21 \
        --disk path=/var/lib/libvirt/images/${VM_NAME}.qcow2,format=qcow2 \
        --disk path=/var/lib/libvirt/images/${VM_NAME}-cidata.iso,device=cdrom \
        --network network=${NETWORK},portgroup=${PORTGROUP},mac=${MAC_ADDRESS} \
        --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
        --graphics none \
        --import \
        --noautoconsole

    virsh autostart ${VM_NAME}

    echo "==> ${VM_NAME} launched (reboot in ~30s)"
    echo "    Monitor: virsh console ${VM_NAME}"
    echo ""

done

echo "==> All demo VMs for ${SITE_NAME} launched"
echo ""
sudo virsh list
