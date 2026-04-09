#!/bin/bash
# 03-packages.sh -- Package installation and base configuration
# Run on the host (home / cottage) after first boot.
# Usage: sudo bash 03-packages.sh
#
# Prerequisites (handled by preseed.cfg):
#   - user lab + sudo NOPASSWD
#   - SSH key in authorized_keys
#   - 4G swapfile
#   - openssh-server, sudo, curl already installed
#   - kvm_intel in /etc/modules-load.d/kvm.conf

set -euo pipefail

echo "=== [03-packages] Start ==="

# -- Update + install packages -------------------------------------------------
echo "--- apt update + install ---"
apt-get update -y
apt-get install -y \
    vim \
    htop \
    iputils-ping \
    bridge-utils \
    netcat-openbsd \
    traceroute \
    tcpdump \
    dnsutils \
    cloud-image-utils \
    libguestfs-tools \
    netplan.io \
    lvm2 \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    libosinfo-bin \
    openvswitch-switch \
    openvswitch-common

# -- Add lab user to required groups -------------------------------------------
echo "--- adding lab to libvirt + kvm groups ---"
usermod -aG libvirt lab
usermod -aG kvm lab

# -- LIBVIRT_DEFAULT_URI -- idempotent ------------------------------------------
grep -q LIBVIRT_DEFAULT_URI /home/lab/.bashrc || \
    echo 'export LIBVIRT_DEFAULT_URI=qemu:///system' >> /home/lab/.bashrc

# -- OpenVSwitch ---------------------------------------------------------------
echo "--- enabling openvswitch-switch ---"
systemctl enable --now openvswitch-switch


# -- KVM module ----------------------------------------------------------------
echo "--- kvm_intel ---"
modprobe kvm_intel 2>/dev/null && echo "kvm_intel loaded" || echo "WARN: modprobe kvm_intel failed -- reboot required"
# Already set in /etc/modules-load.d/kvm.conf via preseed

# -- libvirtd ------------------------------------------------------------------
echo "--- starting libvirtd ---"
systemctl start libvirtd || true

# -- /var/lib/libvirt/images permissions ---------------------------------------
echo "--- libvirt/images permissions ---"
chmod 755 /var/lib/libvirt/images
mkdir -p /var/lib/libvirt/images/iso

# -- Verification --------------------------------------------------------------
echo ""
echo "=== Checks ==="

echo -n "OVS         : "
ovs-vsctl --version | head -1

echo -n "KVM module  : "
lsmod | grep -q kvm && echo "OK" || echo "not yet loaded -- will be active after reboot (kvm.conf OK)"

echo -n "libvirtd    : "
virsh list &>/dev/null && echo "OK" || echo "ERROR"


echo -n "swap        : "
swapon --show | grep -q swapfile && echo "OK" || echo "MISSING"

echo -n "lab groups  : "
groups lab

echo -n "sudo NOPASSWD : "
sudo -n true 2>/dev/null && echo "OK" || echo "ERROR -- check /etc/sudoers.d/lab"

echo ""
echo "=== [03-packages] Done ==="
echo "Next step: source site-X.env && source secrets-X.env && sudo -E bash 04-network.sh"
