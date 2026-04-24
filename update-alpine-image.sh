#!/bin/bash
# update-alpine-image.sh -- Update the Alpine cloud-init base image
#
# Takes the original upstream Alpine nocloud image, expands it, runs
# apk update/upgrade inside a chroot, and produces the "--updated" image
# used by all KVM deployment scripts.
#
# Run on the host (as a user with sudo) after placing the original image
# in /var/lib/libvirt/images/iso/.
#
# Usage:
#   bash update-alpine-image.sh
#   bash update-alpine-image.sh          # then scp to other site (see bottom)
#
# Prerequisites (installed by 03-packages.sh):
#   libguestfs-tools   (guestfish, guestmount, guestunmount)
#   qemu-img

set -euo pipefail

#https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.4-x86_64-bios-cloudinit-r0.qcow2
IMAGE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud"
IMAGE_ORIGINAL_FILE_NAME="nocloud_alpine-3.23.4-x86_64-bios-cloudinit-r0.qcow2"

IMAGE_DIR="/var/lib/libvirt/images/iso"
IMAGE_ORIGINAL="${IMAGE_DIR}/${IMAGE_ORIGINAL_FILE_NAME}"
IMAGE_UPDATED="${IMAGE_DIR}/${IMAGE_ORIGINAL_FILE_NAME}--updated.qcow2"

sudo mkdir -p ${IMAGE_DIR}
# -- Download the Debian netinst ISO if not present ----------------------------
if [[ ! -f "${IMAGE_ORIGINAL}" ]]; then
    echo "=== Downloading Alpine Linux 3.23.4 ISO ==="
    wget "${IMAGE_URL}/${IMAGE_ORIGINAL_FILE_NAME}"
    sudo mv ./${IMAGE_ORIGINAL_FILE_NAME} ${IMAGE_DIR}
else
    echo "=== ISO already present: ${IMAGE_ORIGINAL} ==="
fi

# -- Validate source image -----------------------------------------------------
if [[ ! -f "${IMAGE_ORIGINAL}" ]]; then
    echo "ERROR: source image not found: ${IMAGE_ORIGINAL}"
    echo "Download from: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud"
    exit 1
fi

echo "==> Copying original image -> updated"
sudo cp "${IMAGE_ORIGINAL}" "${IMAGE_UPDATED}"

echo "==> Expanding image (+500M)"
sudo qemu-img resize "${IMAGE_UPDATED}" +500M

echo "==> Expanding ext4 filesystem"
sudo guestfish -a "${IMAGE_UPDATED}" -- \
    run : \
    e2fsck-f /dev/sda : \
    resize2fs /dev/sda

# -- Mount the image -----------------------------------------------------------
MOUNT_DIR=$(mktemp -d)
echo "==> Mounting image at ${MOUNT_DIR}"
sudo guestmount -a "${IMAGE_UPDATED}" -i --rw "${MOUNT_DIR}"

cleanup() {
    echo "==> Cleanup..."
    sudo umount "${MOUNT_DIR}/proc" 2>/dev/null || true
    sudo umount "${MOUNT_DIR}/sys"  2>/dev/null || true
    sudo umount "${MOUNT_DIR}/dev"  2>/dev/null || true
    sudo guestunmount "${MOUNT_DIR}" 2>/dev/null || true
    rmdir "${MOUNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# -- Inject DNS so apk can reach the network ----------------------------------
echo "==> Injecting DNS"
echo "nameserver 8.8.8.8" | sudo tee "${MOUNT_DIR}/etc/resolv.conf" > /dev/null

# -- Bind mounts for chroot ----------------------------------------------------
echo "==> Bind-mounting proc/sys/dev"
sudo mount --bind /proc "${MOUNT_DIR}/proc"
sudo mount --bind /sys  "${MOUNT_DIR}/sys"
sudo mount --bind /dev  "${MOUNT_DIR}/dev"

# -- Update packages inside the image -----------------------------------------
echo "==> Running apk update/upgrade inside chroot"
sudo chroot "${MOUNT_DIR}" /bin/sh -c "
    apk update && \
    apk upgrade && \
    apk cache clean && \
    rm -rf /var/lib/cloud/instance/*
"

# -- Unmount cleanly -----------------------------------------------------------
echo "==> Unmounting"
sudo umount "${MOUNT_DIR}/proc"
sudo umount "${MOUNT_DIR}/sys"
sudo umount "${MOUNT_DIR}/dev"
sudo guestunmount "${MOUNT_DIR}"
rmdir "${MOUNT_DIR}"
trap - EXIT

echo ""
echo "==> Done: ${IMAGE_UPDATED}"
echo ""
echo "To deploy on this site, the image is already in place."
echo ""
echo "To sync to the other site (run from site A to push to site B, or vice versa):"
echo "  scp ${IMAGE_UPDATED} lab@<other-site-host>:${IMAGE_DIR}/"
echo ""
echo "Alternatively, copy the updated image back to this machine and re-run"
echo "the relevant KVM deployment script (07-create-bastion.sh, 08-create-router00.sh, etc.)."
