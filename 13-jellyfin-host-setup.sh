#!/bin/bash
# 13-jellyfin-host-setup.sh -- Prepare c-server00 host for the Jellyfin LXC container
#
# What this script does:
#   1. Install libvirt-daemon-driver-lxc, exfatprogs, debootstrap
#   2. Enable the libvirt LXC driver daemon (virtlxcd)
#   3. Create /mnt/mybook and mount the WD MyBook (exFAT, UUID=56B7-88FB)
#   4. Add /etc/fstab entry (nofail + automount)
#   5. Verify /dev/dri devices exist (VA-API prerequisite)
#   6. Create the container rootfs directory
#   7. Print DNS/DHCP lines to add to site-B.env
#
# Network: LAN10 (10.1.10.0/24) via libvirt portgroup lan10 on br-ext10.
# This keeps Jellyfin in the infra subnet alongside bastions/routers,
# consistent with its role as internal infrastructure (not an app).
#
# Design principle: only libvirt + OVS on the bare metal host.
# LXC via libvirt = virsh for everything, zero extra tooling.
#
# Usage:
#   source site-B.env && source site-B-secrets.env
#   sudo -E bash 13-jellyfin-host-setup.sh
#
# Undo: sudo bash 14-jellyfin-host-teardown.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root: sudo -E bash $0"
    exit 1
fi

for VAR in SITE_NAME SITE_LETTER; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "       Run: source site-B.env && sudo -E bash $0"
        exit 1
    fi
done

if [[ "${SITE_LETTER}" != "c" ]]; then
    echo "ERROR: this script is for site B (chalet) only -- SITE_LETTER=${SITE_LETTER}"
    exit 1
fi

MYBOOK_UUID="56B7-88FB"
MYBOOK_MOUNT="/mnt/mybook"
LXC_FS_DIR="/var/lib/libvirt/filesystems/c-jellyfin"

JELLYFIN_IP="10.1.10.10"
JELLYFIN_NAME="c-jellyfin"
HASH=$(echo -n "${SITE_NAME}::${JELLYFIN_NAME}" | md5sum | awk '{print $1}')
JELLYFIN_MAC="52:54:${HASH:0:2}:${HASH:2:2}:${HASH:4:2}:${HASH:6:2}"

echo "=== [13-jellyfin-host-setup] Start ==="
echo "    Site        : ${SITE_NAME} (${SITE_LETTER})"
echo "    MyBook      : UUID=${MYBOOK_UUID}  mount=${MYBOOK_MOUNT}"
echo "    Network     : LAN10 (lan-ext10 / br-ext10)"
echo "    Jellyfin    : ${JELLYFIN_IP}  MAC: ${JELLYFIN_MAC}"
echo ""

# ------------------------------------------------------------------------------
# 1. Packages
# ------------------------------------------------------------------------------
echo "==> [1/6] Installing packages"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libvirt-daemon-driver-lxc \
    exfatprogs \
    debootstrap

echo "    libvirt-daemon-driver-lxc : OK"
echo "    exfatprogs                : OK"
echo "    debootstrap               : OK"

# ------------------------------------------------------------------------------
# 2. Enable libvirt LXC driver
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/6] Enable libvirt LXC driver"

if systemctl list-unit-files 2>/dev/null | grep -q "^virtlxcd"; then
    systemctl enable --now virtlxcd
    echo "    virtlxcd: enabled and started"
else
    systemctl restart libvirtd
    echo "    libvirtd restarted (LXC driver built-in)"
fi

sleep 1
if virsh -c lxc:/// version &>/dev/null; then
    echo "    lxc:/// URI: OK"
else
    echo "    WARN: lxc:/// URI not responding yet"
fi

# ------------------------------------------------------------------------------
# 3. Mount point + mount WD MyBook
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/6] Mount point and WD MyBook"

mkdir -p "${MYBOOK_MOUNT}"

if ! blkid -U "${MYBOOK_UUID}" &>/dev/null; then
    echo "    WARN: no device found with UUID=${MYBOOK_UUID}"
    echo "          Is the WD MyBook plugged in? fstab will still be written."
else
    MYBOOK_DEV=$(blkid -U "${MYBOOK_UUID}")
    echo "    Device : ${MYBOOK_DEV}"
    if mountpoint -q "${MYBOOK_MOUNT}"; then
        echo "    Already mounted at ${MYBOOK_MOUNT}"
    else
        mount -t exfat -o uid=root,gid=root,umask=022 \
            "UUID=${MYBOOK_UUID}" "${MYBOOK_MOUNT}"
        echo "    Mounted at ${MYBOOK_MOUNT}"
    fi
fi

# ------------------------------------------------------------------------------
# 4. /etc/fstab
# ------------------------------------------------------------------------------
echo ""
echo "==> [4/6] /etc/fstab"

FSTAB_TAG="# jellyfin-mybook"
FSTAB_LINE="UUID=${MYBOOK_UUID}  ${MYBOOK_MOUNT}  exfat  uid=root,gid=root,umask=022,nofail,x-systemd.automount  0  0  ${FSTAB_TAG}"

if grep -qF "${FSTAB_TAG}" /etc/fstab; then
    echo "    fstab entry already present -- skipping"
else
    printf "\n%s\n" "${FSTAB_LINE}" >> /etc/fstab
    echo "    fstab entry added"
fi

systemctl daemon-reload

# ------------------------------------------------------------------------------
# 5. /dev/dri check
# ------------------------------------------------------------------------------
echo ""
echo "==> [5/6] /dev/dri devices (VA-API)"

if [[ ! -d /dev/dri ]]; then
    echo "    ERROR: /dev/dri not found -- check: dmesg | grep -i amdgpu"
    exit 1
fi

ls -la /dev/dri/ | grep -vE '^total|^\.|^d' | while read -r line; do
    echo "    ${line}"
done
echo "    /dev/dri: OK"

# ------------------------------------------------------------------------------
# 6. Container rootfs directory
# ------------------------------------------------------------------------------
echo ""
echo "==> [6/6] Container rootfs directory"

mkdir -p "${LXC_FS_DIR}"
echo "    Created: ${LXC_FS_DIR}"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  [13-jellyfin-host-setup] Complete"
echo ""
echo "  Packages    : libvirt-lxc exfatprogs debootstrap"
echo "  LXC driver  : enabled"
echo "  WD MyBook   : ${MYBOOK_MOUNT} (UUID=${MYBOOK_UUID})"
echo "  /dev/dri    : present"
echo "  Container FS: ${LXC_FS_DIR}"
echo "  Network     : LAN10 (10.1.10.0/24) via lan-ext10 / br-ext10"
echo ""
echo "  site-B.env additions (if not already present):"
echo "  -----------------------------------------------"
echo "  In DHCP_STATIC_HOSTS, add:"
echo "    dhcp-host=${JELLYFIN_MAC},${JELLYFIN_NAME},${JELLYFIN_IP}"
echo ""
echo "  In DNS_STATIC, add:"
echo "    host-record=${JELLYFIN_NAME}.chalet.lab,${JELLYFIN_NAME},${JELLYFIN_IP}"
echo ""
echo "  Then re-run 09-create-router00.sh to push dnsmasq config."
echo ""
echo "  Computed MAC : ${JELLYFIN_MAC}"
echo "  Next step    : sudo -E bash 15-create-jellyfin-lxc.sh"
echo "================================================================"
