#!/bin/bash
# 16-create-debian-13-vms.sh -- Create one or more Debian 13 KVM VMs
#
# Generic script for creating Debian 13 VMs on any LAN.
# k3s-specific setup (node roles, k3s install) is handled by 17-install-k3s.sh.
#
# Usage:
#   source site-X.env && source site-X-secrets.env
#   sudo -E bash 16-create-debian-13-vms.sh [OPTIONS] "VM_SPECS"
#
# VM_SPECS format (comma-separated):
#   NAME:IP_OR_DHCP:VCPUS:MEM_MB
#
#   NAME        : VM hostname (e.g. m-k3s-server)
#   IP_OR_DHCP  : static IP (e.g. 10.0.10.20) or 'dhcp'
#   VCPUS       : number of vCPUs
#   MEM_MB      : RAM in MB
#
# OPTIONS:
#   --network  NETWORK    libvirt network name    (default: lan-ext10)
#   --portgroup PORTGROUP libvirt portgroup name  (default: lan10)
#   --disk     SIZE       disk size               (default: 32G)
#   --cpu      CPU_MODEL  CPU model               (default: host-passthrough)
#                         use 'host-model' for cross-host migration compatibility
#   --extra-pubkey KEY    additional SSH public key to install (e.g. INTRA_LAB_PUBLIC_KEY)
#
# Examples:
#   # k3s nodes on LAN10 with DHCP
#   sudo -E bash 16-create-debian-13-vms.sh "m-k3s-server:dhcp:2:4096,m-k3s-agent-1:dhcp:4:8192"
#
#   # App VMs on LAN20 with static IPs
#   sudo -E bash 16-create-debian-13-vms.sh \
#     --network lan-int --portgroup lan20 \
#     "m-app-1:10.0.20.10:2:4096"
#
#   # Minimal VM on LAN30, no host-passthrough
#   sudo -E bash 16-create-debian-13-vms.sh \
#     --network lan-int --portgroup lan30 --cpu host-model \
#     "m-test-1:dhcp:1:1024"
#
# Required env vars (from site-X.env + site-X-secrets.env):
#   SITE_NAME  SITE_LETTER  PRIMARY_DOMAIN
#   DEBIAN_EFFECTIVE_IMAGE_TO_USE
#   LAB_SSH_PUBKEY  LAB_PASSWORD  ROOT_PASSWORD

set -euo pipefail

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
NETWORK="lan-ext10"
PORTGROUP="lan10"
DISK_SIZE="32G"
CPU_MODEL="host-passthrough"
EXTRA_PUBKEY=""

# ------------------------------------------------------------------------------
# Parse options
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --network)   NETWORK="$2";    shift 2 ;;
        --portgroup) PORTGROUP="$2";  shift 2 ;;
        --disk)      DISK_SIZE="$2";  shift 2 ;;
        --cpu)       CPU_MODEL="$2";  shift 2 ;;
        --extra-pubkey) EXTRA_PUBKEY="$2"; shift 2 ;;
        --*)
            echo "ERROR: unknown option: $1"
            echo "Usage: sudo -E bash $0 [--network N] [--portgroup P] [--disk S] [--cpu C] [--extra-pubkey KEY] \"VM_SPECS\""
            exit 1
            ;;
        *) break ;;   # VM_SPECS positional argument
    esac
done

VM_SPECS_ARG="${1:-}"

if [[ -z "${VM_SPECS_ARG}" ]]; then
    echo "ERROR: VM spec argument required"
    echo "Usage: sudo -E bash $0 [OPTIONS] \"name:ip_or_dhcp:vcpus:mem_mb,...\""
    echo "Example:"
    echo "  sudo -E bash $0 \"m-k3s-server:dhcp:2:4096,m-k3s-agent-1:dhcp:4:8192\""
    exit 1
fi

# ------------------------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root: sudo -E bash $0"
    exit 1
fi

for VAR in SITE_NAME SITE_LETTER PRIMARY_DOMAIN \
           DEBIAN_EFFECTIVE_IMAGE_TO_USE \
           LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "       source site-X.env && source site-X-secrets.env && sudo -E bash $0"
        exit 1
    fi
done

IMAGE_PATH="/var/lib/libvirt/images/iso/${DEBIAN_EFFECTIVE_IMAGE_TO_USE}"
if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "ERROR: base image not found: ${IMAGE_PATH}"
    echo "       Run 04-download-update-debian-image.sh first."
    exit 1
fi

# Parse VM specs
IFS=',' read -ra VM_SPECS <<< "${VM_SPECS_ARG}"

echo "=== [16-create-debian-13-vms] Start ==="
echo "    Site      : ${SITE_NAME} (${SITE_LETTER})"
echo "    Image     : ${DEBIAN_EFFECTIVE_IMAGE_TO_USE}"
echo "    Network   : ${NETWORK} / ${PORTGROUP}"
echo "    Disk      : ${DISK_SIZE}"
echo "    CPU model : ${CPU_MODEL}"
echo "    VMs       : ${#VM_SPECS[@]}"
for SPEC in "${VM_SPECS[@]}"; do
    IFS=: read -r VM_NAME IP_OR_DHCP VCPUS MEM_MB <<< "${SPEC}"
    echo "      ${VM_NAME}  ip=${IP_OR_DHCP}  ${VCPUS}vCPU  ${MEM_MB}MB"
done
echo ""

# Collect SSH keys to install
SSH_KEYS=("${LAB_SSH_PUBKEY}")
[[ -n "${EXTRA_PUBKEY}" ]] && SSH_KEYS+=("${EXTRA_PUBKEY}")

# Build authorized_keys block for cloud-init
AUTHORIZED_KEYS_YAML=""
for KEY in "${SSH_KEYS[@]}"; do
    AUTHORIZED_KEYS_YAML+="      - ${KEY}"$'\n'
done

# ------------------------------------------------------------------------------
# Create VMs
# ------------------------------------------------------------------------------
for SPEC in "${VM_SPECS[@]}"; do
    IFS=: read -r VM_NAME IP_OR_DHCP VCPUS MEM_MB <<< "${SPEC}"

    HASH=$(echo -n "${SITE_NAME}::${VM_NAME}" | md5sum | awk '{print $1}')
    MAC_ADDRESS="52:54:${HASH:0:2}:${HASH:2:2}:${HASH:4:2}:${HASH:6:2}"

    echo "==> [VM] ${VM_NAME}  ip=${IP_OR_DHCP}  MAC=${MAC_ADDRESS}  ${VCPUS}vCPU/${MEM_MB}MB"

    # Network config for cloud-init
    if [[ "${IP_OR_DHCP}" == "dhcp" ]]; then
        NETWORK_FILE_CONTENT="[Match]
Name=en*

[Network]
DHCP=ipv4

[DHCP]
UseDNS=yes
UseDomains=yes"
    else
        IP_PREFIX=$(echo "${IP_OR_DHCP}" | cut -d. -f1-3)
        GW="${IP_PREFIX}.1"
        NETWORK_FILE_CONTENT="[Match]
Name=en*

[Network]
Address=${IP_OR_DHCP}/24
Gateway=${GW}
DNS=${GW}
Domains=${PRIMARY_DOMAIN}"
    fi

    # Clean up existing VM
    virsh destroy  "${VM_NAME}" 2>/dev/null && echo "    Stopped ${VM_NAME}"  || true
    virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null \
        && echo "    Undefined ${VM_NAME}" || true
    rm -f "/var/lib/libvirt/images/${VM_NAME}.qcow2"
    rm -f "/var/lib/libvirt/images/${VM_NAME}-cidata.iso"

    # Build cloud-init
    CIDATA="/tmp/${VM_NAME}-cidata"
    rm -rf "${CIDATA}"
    mkdir -p "${CIDATA}"

    cat > "${CIDATA}/meta-data" << EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    # Write user-data with proper indentation for authorized_keys
    cat > "${CIDATA}/user-data" << EOF
#cloud-config
hostname: ${VM_NAME}
timezone: America/Montreal

ssh_pwauth: true

packages:
  - qemu-guest-agent
  - curl
  - tcpdump
  - htop
  - bind9-dnsutils
  - iputils-ping
  - netcat-openbsd

users:
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
${AUTHORIZED_KEYS_YAML}
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
        ${VM_NAME}  |  ${SITE_NAME}
        Network: ${NETWORK} / ${PORTGROUP}  |  IP: ${IP_OR_DHCP}
      ================================================================================

  - path: /etc/systemd/network/10-enp.network
    content: |
$(echo "${NETWORK_FILE_CONTENT}" | sed 's/^/      /')

  - path: /etc/sysctl.d/99-net.conf
    content: |
      net.ipv4.ip_forward = 1
      net.ipv6.conf.all.disable_ipv6 = 1

  - path: /home/lab/.ssh/config
    owner: lab:lab
    permissions: '0600'
    content: |
      Host 10.0.* m-server00 m-router00 m-bastion m-demo-*-lan* m-k3s-* 10.1.* c-server00 c-router00 c-bastion c-demo-*-lan* c-jellyfin c-nutserver c-k3s-*
          User lab
          IdentityFile ~/.ssh/id_ed25519_intra_lab
          ForwardAgent yes
          IdentitiesOnly yes
          StrictHostKeyChecking no
          UserKnownHostsFile ~/.ssh/known_hosts.intra_lab

runcmd:
  - sysctl --system
  - systemctl enable qemu-guest-agent
  - systemctl start  qemu-guest-agent
  - systemctl restart systemd-networkd
  - touch /etc/cloud/cloud-init.disabled
EOF

    # If EXTRA_PUBKEY (INTRA_LAB), also write the private key for outbound SSH
    if [[ -n "${EXTRA_PUBKEY}" && -n "${INTRA_LAB_PRIVATE_KEY:-}" ]]; then
        PRIVKEY_B64="${INTRA_LAB_PRIVATE_KEY}"
        cat >> "${CIDATA}/user-data" << EOF

  - path: /home/lab/.ssh/id_ed25519_intra_lab
    owner: lab:lab
    permissions: '0600'
    encoding: b64
    content: ${PRIVKEY_B64}
EOF
    fi

    genisoimage \
        -output "/var/lib/libvirt/images/${VM_NAME}-cidata.iso" \
        -volid cidata \
        -joliet -rock \
        "${CIDATA}/user-data" \
        "${CIDATA}/meta-data"

    # Disk
    cp "${IMAGE_PATH}" "/var/lib/libvirt/images/${VM_NAME}.qcow2"
    qemu-img resize "/var/lib/libvirt/images/${VM_NAME}.qcow2" "${DISK_SIZE}"

    # virt-install
    virt-install \
        --name "${VM_NAME}" \
        --memory "${MEM_MB}" \
        --vcpus "${VCPUS}" \
        --cpu "${CPU_MODEL}" \
        --os-variant debian13 \
        --disk "path=/var/lib/libvirt/images/${VM_NAME}.qcow2,format=qcow2,bus=virtio" \
        --disk "path=/var/lib/libvirt/images/${VM_NAME}-cidata.iso,device=cdrom" \
        --network "network=${NETWORK},portgroup=${PORTGROUP},mac=${MAC_ADDRESS}" \
        --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
        --graphics none \
        --serial pty \
        --console pty,target_type=serial \
        --import \
        --noautoconsole

    virsh autostart "${VM_NAME}"
    echo "    ${VM_NAME}: created, autostart enabled"
    echo ""
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo "================================================================"
echo "  [16-create-debian-13-vms] Complete -- ${SITE_NAME}"
echo ""
echo "  Network   : ${NETWORK} / ${PORTGROUP}"
echo "  CPU model : ${CPU_MODEL}"
echo "  VMs created:"
for SPEC in "${VM_SPECS[@]}"; do
    IFS=: read -r VM_NAME IP_OR_DHCP VCPUS MEM_MB <<< "${SPEC}"
    HASH=$(echo -n "${SITE_NAME}::${VM_NAME}" | md5sum | awk '{print $1}')
    MAC="52:54:${HASH:0:2}:${HASH:2:2}:${HASH:4:2}:${HASH:6:2}"
    echo "    ${VM_NAME}  MAC=${MAC}  ${VCPUS}vCPU/${MEM_MB}MB  ip=${IP_OR_DHCP}"
    if [[ "${IP_OR_DHCP}" == "dhcp" ]]; then
        echo "      Add to site-${SITE_LETTER^^}.env DHCP_STATIC_HOSTS:"
        echo "        dhcp-host=${MAC},${VM_NAME},<chosen-ip>"
        echo "      Add to site-${SITE_LETTER^^}.env DNS_STATIC:"
        echo "        host-record=${VM_NAME}.${PRIMARY_DOMAIN},${VM_NAME},<chosen-ip>"
    fi
done
echo ""
echo "  cloud-init runs on first boot (~2 min)"
echo "  Watch: sudo virsh console <vm-name>   (Ctrl-] to exit)"
echo ""
echo "  After DNS/DHCP is configured:"
echo "    Re-run 09-create-router00.sh on each site"
echo "    Then: bash 17-install-k3s.sh  (for k3s nodes)"
echo "================================================================"
