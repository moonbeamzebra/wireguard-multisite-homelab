#!/bin/bash
# 03-packages.sh -- Version AMD / Debian 13 / Sans Netplan
set -euo pipefail

echo "=== [03-packages] Start (AMD Host Edition - No Netplan) ==="

# -- Mise à jour + Installation des paquets ------------------------------------
echo "--- apt update + install ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Note : On installe 'ifupdown' et 'resolvconf' pour la gestion native du réseau
# On retire 'netplan.io' de la liste.
apt-get install -y \
    vim htop curl wget \
    iputils-ping bridge-utils netcat-openbsd traceroute tcpdump dnsutils \
    pciutils zram-tools rsync \
    cloud-image-utils libguestfs-tools \
    lvm2 ifupdown resolvconf lm-sensors ethtool \
    qemu-kvm libvirt-daemon-system libvirt-clients virtinst libosinfo-bin virt-top ksmtuned \
    openvswitch-switch openvswitch-common

# -- Ajout de l'utilisateur lab aux groupes requis -----------------------------
echo "--- adding lab to libvirt + kvm groups ---"
usermod -aG libvirt lab
usermod -aG kvm lab

# -- Configuration de l'URI Libvirt par défaut ---------------------------------
grep -q "LIBVIRT_DEFAULT_URI" /home/lab/.bashrc || echo "export LIBVIRT_DEFAULT_URI=qemu:///system" >> /home/lab/.bashrc

# -- Activation d'Open vSwitch -------------------------------------------------
echo "--- enabling openvswitch-switch ---"
systemctl enable --now openvswitch-switch

echo "--- enabling ksmtuned ---"
systemctl enable --now ksm ksmtuned

# -- Chargement du module KVM AMD --------------------------------------------
echo "--- kvm_amd ---"
modprobe kvm_amd 2>/dev/null && echo "kvm_amd loaded" || echo "WARN: kvm_amd failed to load (check VT-x in VMware)"

# -- Démarrage de libvirtd -----------------------------------------------------
echo "--- starting libvirtd ---"
systemctl enable --now libvirtd

# -- Droits sur le stockage des images -----------------------------------------
echo "--- libvirt/images permissions ---"
chmod 755 /var/lib/libvirt/images
mkdir -p /var/lib/libvirt/images/iso
chown -R root:libvirt /var/lib/libvirt/images

cat << EOF | sudo tee /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
sudo systemctl restart zramswap

cat << EOF | sudo tee /etc/motd
================================================================================
  BARE METAL HOST - SITE: ${SITE_NAME^^}
================================================================================
  Hardware: GMKtec M7 Ultra (Ryzen 6850U - 8C/16T)
  Role    : KVM Hypervisor & Management

  QUICK HEALTH CHECKS:
  --------------------
  1. System Load : uptime && free -h
  2. KVM Status  : virsh list --all
  3. Storage     : lsblk && df -h /var/lib/libvirt/images
  4. CPU Temp    : sensors | grep Tctl
  5. Network     : brctl show && ovs-vsctl show
  6. Swap        : sudo zramctl && sudo swapon --show

  VM MANAGEMENT:
  --------------
  - Console Access : virsh console <vm-name>
  - Resource Usage : virt-top
  - Locked Memory  : grep "VmLck" /proc/\$(pgrep -f <vm-name>)/status
  - Kernel Log     : dmesg -T | grep -iE 'error|warn|iommu|amd'

  OPTIMIZATIONS: IPv6=Disabled, ASPM=Off, Swappiness=10
================================================================================
EOF

# -- Host performance tuning ---------------------------------------------------
echo "--- Tuning host swappiness ---"
echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf

# -- Vérifications finales -----------------------------------------------------
echo ""
echo "=== Checks ==="
echo -n "OVS         : " && ovs-vsctl --version | head -1
echo -n "KVM AMD     : " && lsmod | grep -q kvm_amd && echo "OK" || echo "FAIL"
echo -n "Network     : " && [ -f /etc/network/interfaces ] && echo "Native Debian (OK)" || echo "Missing /etc/network/interfaces"

echo "=== Fin du script 03-packages.sh ==="