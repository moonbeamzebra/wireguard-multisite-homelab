#!/bin/bash
# 03-packages.sh -- Version Intel / Debian 13 / Sans Netplan
set -euo pipefail

echo "=== [03-packages] Start (Intel Host Edition - No Netplan) ==="

# -- Mise à jour + Installation des paquets ------------------------------------
echo "--- apt update + install ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Note : On installe 'ifupdown' et 'resolvconf' pour la gestion native du réseau
# On retire 'netplan.io' de la liste.
apt-get install -y \
    vim htop curl wget \
    iputils-ping bridge-utils netcat-openbsd traceroute tcpdump dnsutils \
    pciutils \
    cloud-image-utils libguestfs-tools \
    lvm2 ifupdown resolvconf \
    qemu-kvm libvirt-daemon-system libvirt-clients virtinst libosinfo-bin \
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

# -- Chargement du module KVM Intel --------------------------------------------
echo "--- kvm_intel ---"
modprobe kvm_intel 2>/dev/null && echo "kvm_intel loaded" || echo "WARN: kvm_intel failed to load (check VT-x in VMware)"

# -- Démarrage de libvirtd -----------------------------------------------------
echo "--- starting libvirtd ---"
systemctl enable --now libvirtd

# -- Droits sur le stockage des images -----------------------------------------
echo "--- libvirt/images permissions ---"
chmod 755 /var/lib/libvirt/images
mkdir -p /var/lib/libvirt/images/iso
chown -R root:libvirt /var/lib/libvirt/images

# -- Vérifications finales -----------------------------------------------------
echo ""
echo "=== Checks ==="
echo -n "OVS         : " && ovs-vsctl --version | head -1
echo -n "KVM Intel   : " && lsmod | grep -q kvm_intel && echo "OK" || echo "FAIL"
echo -n "Netplan     : " && command -v netplan >/dev/null && echo "STILL PRESENT" || echo "NOT INSTALLED (OK)"
echo -n "Network     : " && [ -f /etc/network/interfaces ] && echo "Native Debian (OK)" || echo "Missing /etc/network/interfaces"

echo "=== Fin du script 03-packages.sh ==="