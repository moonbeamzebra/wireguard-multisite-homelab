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
    pciutils \
    cloud-image-utils libguestfs-tools \
    lvm2 ifupdown resolvconf \
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

# -- Vérifications finales -----------------------------------------------------
echo ""
echo "=== Checks ==="
echo -n "OVS         : " && ovs-vsctl --version | head -1
echo -n "KVM AMD     : " && lsmod | grep -q kvm_amd && echo "OK" || echo "FAIL"
echo -n "Network     : " && [ -f /etc/network/interfaces ] && echo "Native Debian (OK)" || echo "Missing /etc/network/interfaces"

echo "=== Fin du script 03-packages.sh ==="