#!/bin/bash
# 02-packages.sh -- Install host packages and apply base configuration
#
# Run as root on the freshly installed server00.
# SITE_NAME must be set (from site-*.env) for the motd.
#
# Usage:
#   source site-A.env && source site-A-secrets.env
#   sudo -E bash 02-packages.sh

set -euo pipefail

echo "=== [02-packages] Start ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

apt-get install -y \
    \
    `# --- Utilities ---` \
    vim htop curl wget rsync \
    \
    `# --- Networking ---` \
    iputils-ping traceroute tcpdump netcat-openbsd \
    bridge-utils ethtool dnsutils \
    \
    `# --- Storage ---` \
    lvm2 pciutils \
    \
    `# --- System ---` \
    lm-sensors zram-tools \
    ifupdown resolvconf \
    \
    `# --- KVM / libvirt ---` \
    qemu-kvm libvirt-daemon-system libvirt-clients \
    virtinst libosinfo-bin virt-top ksmtuned \
    \
    `# --- Cloud image tools ---` \
    cloud-image-utils libguestfs-tools genisoimage \
    \
    `# --- Open vSwitch ---` \
    openvswitch-switch openvswitch-common \
    \
    `# --- Security ---` \
    fail2ban iptables iptables-persistent

# -- User and groups -----------------------------------------------------------
echo "--- Adding lab to libvirt and kvm groups ---"
usermod -aG libvirt lab
usermod -aG kvm lab

grep -q "LIBVIRT_DEFAULT_URI" /home/lab/.bashrc \
    || echo "export LIBVIRT_DEFAULT_URI=qemu:///system" >> /home/lab/.bashrc

# -- Services ------------------------------------------------------------------
echo "--- Enabling services ---"
systemctl enable --now openvswitch-switch
systemctl enable --now ksm ksmtuned
systemctl enable --now libvirtd

# -- KVM AMD module ------------------------------------------------------------
echo "--- Loading kvm_amd ---"
modprobe kvm_amd 2>/dev/null \
    && echo "kvm_amd loaded" \
    || echo "WARN: kvm_amd failed to load -- check SVM Mode in BIOS"

# -- Storage permissions -------------------------------------------------------
echo "--- Setting up libvirt image storage ---"
chmod 755 /var/lib/libvirt/images
mkdir -p /var/lib/libvirt/images/iso
chown -R root:libvirt /var/lib/libvirt/images

# -- zram swap -----------------------------------------------------------------
# Allocate 50% of RAM as compressed swap (zstd). On a 32 GB host this provides
# ~16 GB of effective swap with minimal latency. Adjust PERCENT if needed.
cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl restart zramswap

# -- Host performance tuning ---------------------------------------------------
# Lower swappiness to prefer RAM over swap for KVM workloads.
echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
sysctl -p /etc/sysctl.d/99-swappiness.conf

# -- motd ----------------------------------------------------------------------
cat > /etc/motd << EOF
================================================================================
  BARE METAL HOST - SITE: ${SITE_NAME^^}
================================================================================
  Hardware: GMKtec M7 Ultra (Ryzen 6850U - 8C/16T)
  Role    : KVM Hypervisor and Management

  QUICK HEALTH CHECKS:
  --------------------
  1. System Load : uptime && free -h
  2. KVM Status  : virsh list --all
  3. Storage     : lsblk && df -h /var/lib/libvirt/images
  4. CPU Temp    : sensors | grep Tctl
  5. Network     : brctl show && ovs-vsctl show
  6. Swap        : zramctl && swapon --show

  VM MANAGEMENT:
  --------------
  - Console Access : virsh console <vm-name>
  - Resource Usage : virt-top
  - Kernel Log     : dmesg -T | grep -iE 'error|warn|iommu|amd'
================================================================================
EOF

# -- Verification --------------------------------------------------------------
echo ""
echo "=== Checks ==="
echo -n "OVS     : " && ovs-vsctl --version | head -1
echo -n "kvm_amd : " && (lsmod | grep -q kvm_amd && echo "OK" || echo "FAIL")

echo "=== [02-packages] Done ==="
