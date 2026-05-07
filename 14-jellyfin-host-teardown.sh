#!/bin/bash
# 14-jellyfin-host-teardown.sh -- Undo everything done by 13-jellyfin-host-setup.sh
#
# What this script undoes:
#   1. Destroys and undefines the c-jellyfin LXC container (if running)
#   2. Removes the container rootfs directory
#   3. Unmounts the WD MyBook
#   4. Removes the /etc/fstab entry
#   5. Stops the virtlxcd daemon
#   (Packages left installed -- harmless and slow to re-download)
#
# Usage:
#   sudo bash 14-jellyfin-host-teardown.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root: sudo bash $0"
    exit 1
fi

MYBOOK_MOUNT="/mnt/mybook"
FSTAB_TAG="# jellyfin-mybook"
LXC_FS_DIR="/var/lib/libvirt/filesystems/c-jellyfin"
VM_NAME="c-jellyfin"

echo "=== [14-jellyfin-host-teardown] Start ==="
echo ""

# ------------------------------------------------------------------------------
# 1. Destroy and undefine LXC container
# ------------------------------------------------------------------------------
echo "==> [1/5] LXC container '${VM_NAME}'"

if virsh -c lxc:/// dominfo "${VM_NAME}" &>/dev/null; then
    STATE=$(virsh -c lxc:/// domstate "${VM_NAME}" 2>/dev/null || echo "unknown")
    if [[ "${STATE}" == "running" ]]; then
        virsh -c lxc:/// destroy "${VM_NAME}" && echo "    Stopped ${VM_NAME}" || true
    fi
    virsh -c lxc:/// undefine "${VM_NAME}" && echo "    Undefined ${VM_NAME}" || true
else
    echo "    Container '${VM_NAME}' not defined -- skipping"
fi

# ------------------------------------------------------------------------------
# 2. Remove container rootfs
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/5] Container rootfs: ${LXC_FS_DIR}"

if [[ -d "${LXC_FS_DIR}" ]]; then
    rm -rf "${LXC_FS_DIR}"
    echo "    Removed ${LXC_FS_DIR}"
else
    echo "    Not found -- skipping"
fi

# ------------------------------------------------------------------------------
# 3. Unmount WD MyBook
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/5] Unmount WD MyBook"

if mountpoint -q "${MYBOOK_MOUNT}" 2>/dev/null; then
    umount -l "${MYBOOK_MOUNT}" && echo "    Unmounted ${MYBOOK_MOUNT}"
else
    echo "    Not mounted -- skipping"
fi

systemctl daemon-reload

# ------------------------------------------------------------------------------
# 4. Remove /etc/fstab entry
# ------------------------------------------------------------------------------
echo ""
echo "==> [4/5] /etc/fstab"

if grep -qF "${FSTAB_TAG}" /etc/fstab; then
    grep -vF "${FSTAB_TAG}" /etc/fstab | grep -v "UUID=56B7-88FB" > /tmp/fstab.new
    mv /tmp/fstab.new /etc/fstab
    echo "    fstab entry removed"
else
    echo "    No entry found -- skipping"
fi

systemctl daemon-reload

# ------------------------------------------------------------------------------
# 5. Stop virtlxcd
# ------------------------------------------------------------------------------
echo ""
echo "==> [5/5] Stop virtlxcd"

if systemctl is-active --quiet virtlxcd 2>/dev/null; then
    systemctl stop virtlxcd
    echo "    virtlxcd stopped"
else
    echo "    virtlxcd not running -- skipping"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  [14-jellyfin-host-teardown] Complete"
echo ""
echo "  LXC container : undefined"
echo "  Rootfs        : removed"
echo "  WD MyBook     : unmounted"
echo "  /etc/fstab    : entry removed"
echo "  virtlxcd      : stopped"
echo ""
echo "  NOTE: packages (libvirt-lxc, exfatprogs, debootstrap)"
echo "        are still installed. Remove manually if desired:"
echo "          apt-get remove libvirt-daemon-driver-lxc exfatprogs debootstrap"
echo ""
echo "  To start fresh: sudo -E bash 13-jellyfin-host-setup.sh"
echo "================================================================"
