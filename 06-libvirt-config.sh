#!/bin/bash
# 06-libvirt-config.sh -- libvirt post-install configuration
# Usage: sudo bash 06-libvirt-config.sh
#
# What this does:
#   - ON_SHUTDOWN=shutdown : Gracefully power off KVMs on host shutdown (Clean state)
#   - ON_BOOT=start        : Start autostart-enabled KVMs on host boot
#   - Configure system limits for locked memory (memlock)
#   - Optimize host swappiness for VM performance
#   - Disable the default libvirt bridge (virbr0)

set -euo pipefail

echo "=== [06-libvirt-config] Start ==="

# -- libvirt-guests: Clean shutdown/boot logic --------------------------------
echo "--- Configuring libvirt-guests (Shutdown mode) ---"

LIBVIRT_GUESTS_CONF=/etc/default/libvirt-guests

# Ensure configuration is clean using sed
sed -i 's/^#*ON_SHUTDOWN=.*/ON_SHUTDOWN=shutdown/'      ${LIBVIRT_GUESTS_CONF}
sed -i 's/^#*ON_BOOT=.*/ON_BOOT=start/'                ${LIBVIRT_GUESTS_CONF}
sed -i 's/^#*SHUTDOWN_TIMEOUT=.*/SHUTDOWN_TIMEOUT=30/'  ${LIBVIRT_GUESTS_CONF}
sed -i 's/^#*START_DELAY=.*/START_DELAY=0/'            ${LIBVIRT_GUESTS_CONF}
sed -i 's/^#*PARALLEL_SHUTDOWN=.*/PARALLEL_SHUTDOWN=5/' ${LIBVIRT_GUESTS_CONF}

# Idempotent check (add if totally missing)
grep -q '^ON_SHUTDOWN=' ${LIBVIRT_GUESTS_CONF} || echo 'ON_SHUTDOWN=shutdown' >> ${LIBVIRT_GUESTS_CONF}
grep -q '^ON_BOOT='     ${LIBVIRT_GUESTS_CONF} || echo 'ON_BOOT=start'     >> ${LIBVIRT_GUESTS_CONF}

systemctl enable libvirt-guests
systemctl restart libvirt-guests
echo "libvirt-guests: $(systemctl is-active libvirt-guests)"

# -- Disable the default libvirt network ---------------------------------------
echo "--- Disabling default libvirt network ---"
if virsh net-info default &>/dev/null; then
    virsh net-destroy  default 2>/dev/null || true
    virsh net-autostart default --disable 2>/dev/null || true
    echo "default bridge: disabled"
else
    echo "default bridge: not present (OK)"
fi

# -- Configure system limits (Locked Memory) -----------------------------------
echo "--- Configuring system limits (memlock) ---"
cat << EOF | sudo tee /etc/security/limits.d/libvirt-memlock.conf
# Allow libvirt-qemu to lock all RAM (Required for locked=yes)
libvirt-qemu    soft    memlock         unlimited
libvirt-qemu    hard    memlock         unlimited
EOF

# Override Systemd Libvirt limits
echo "--- Overriding Systemd Libvirt limits ---"
LIBVIRT_OVERRIDE_DIR=/etc/systemd/system/libvirtd.service.d
sudo mkdir -p ${LIBVIRT_OVERRIDE_DIR}
cat << EOF | sudo tee ${LIBVIRT_OVERRIDE_DIR}/override.conf
[Service]
LimitMEMLOCK=infinity
EOF

# -- Host performance tuning ---------------------------------------------------
echo "--- Tuning host swappiness ---"
echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf

# Reload libvirtd to apply memlock and service overrides
echo "--- Restarting libvirtd ---"
sudo systemctl daemon-reload
sudo systemctl restart libvirtd

echo "=== [06-libvirt-config] Done ==="
