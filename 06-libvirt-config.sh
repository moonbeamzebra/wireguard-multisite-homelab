#!/bin/bash
# 06-libvirt-config.sh -- libvirt post-install configuration
# Run on the host after 05-libvirt-nets.sh
# Usage: sudo bash 06-libvirt-config.sh
#
# What this does:
#   - ON_SHUTDOWN=suspend : suspend KVMs on host shutdown instead of powering off
#   - ON_BOOT=start       : resume suspended KVMs on host boot
#   - Disable the 'default' libvirt network (we use our own)

set -euo pipefail

echo "=== [06-libvirt-config] Start ==="

# -- libvirt-guests: suspend/resume KVMs on host reboot -----------------------
echo "--- Configuring libvirt-guests ---"

LIBVIRT_GUESTS_CONF=/etc/default/libvirt-guests

sed -i 's/^#*ON_SHUTDOWN=.*/ON_SHUTDOWN=suspend/'        ${LIBVIRT_GUESTS_CONF}
sed -i 's/^#*ON_BOOT=.*/ON_BOOT=start/'                  ${LIBVIRT_GUESTS_CONF}
sed -i 's/^#*START_DELAY=.*/START_DELAY=0/'              ${LIBVIRT_GUESTS_CONF}
sed -i 's/^#*PARALLEL_SHUTDOWN=.*/PARALLEL_SHUTDOWN=5/'  ${LIBVIRT_GUESTS_CONF}

# Add lines if absent (idempotent)
grep -q '^ON_SHUTDOWN='       ${LIBVIRT_GUESTS_CONF} || echo 'ON_SHUTDOWN=suspend'    >> ${LIBVIRT_GUESTS_CONF}
grep -q '^ON_BOOT='           ${LIBVIRT_GUESTS_CONF} || echo 'ON_BOOT=start'          >> ${LIBVIRT_GUESTS_CONF}
grep -q '^START_DELAY='       ${LIBVIRT_GUESTS_CONF} || echo 'START_DELAY=0'          >> ${LIBVIRT_GUESTS_CONF}
grep -q '^PARALLEL_SHUTDOWN=' ${LIBVIRT_GUESTS_CONF} || echo 'PARALLEL_SHUTDOWN=5'    >> ${LIBVIRT_GUESTS_CONF}

echo "--- libvirt-guests config ---"
grep -E '^(ON_SHUTDOWN|ON_BOOT|START_DELAY|PARALLEL_SHUTDOWN)' ${LIBVIRT_GUESTS_CONF}

systemctl enable libvirt-guests
systemctl start  libvirt-guests
echo "libvirt-guests: $(systemctl is-active libvirt-guests)"

# -- Disable the default libvirt network ---------------------------------------
echo "--- Disabling default libvirt network ---"
if virsh net-info default &>/dev/null; then
    virsh net-destroy  default 2>/dev/null || true
    virsh net-autostart default --disable 2>/dev/null || true
    echo "default: disabled"
else
    echo "default: not present (OK)"
fi

# -- Final checks --------------------------------------------------------------
echo ""
echo "=== Libvirt networks ==="
virsh net-list --all

echo ""
echo "=== KVMs and autostart ==="
virsh list --all

echo ""
echo "=== [06-libvirt-config] Done ==="
