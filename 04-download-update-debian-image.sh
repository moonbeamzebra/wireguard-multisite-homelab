#!/bin/bash
# 03c-download-update-debian-image.sh
#
# Downloads the official Debian 13 (trixie) generic cloud image, runs
# apt upgrade, and applies the minimal patches required to boot headless
# KVM VMs (--graphics none) with cloud-init.
#
# Philosophy: keep the image as close to the original as possible.
# Only changes strictly required to make the image work in this KVM
# environment are applied here. User-facing packages and configuration
# belong in the cloud-config user-data, not here.
#
# Changes applied to the image:
#   1. apt upgrade          -- keep image current
#   2. GRUB serial patch    -- without it GRUB hangs on gfxterm when no VGA
#                              device is present (--graphics none)
#   3. machine-id cleared   -- each cloned VM must generate its own at boot
#   4. systemd-firstboot    -- masked so cloud-init owns first-boot config
#
# Usage:
#   source site-A-GMKtec.env && bash 03c-download-update-debian-image.sh
#   source site-B-GMKtec.env && bash 03c-download-update-debian-image.sh
#
# Prerequisites (installed by 03-packages.sh):
#   libguestfs-tools  (virt-customize, virt-resize, virt-cat)
#   qemu-img, wget

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Configuration
# ------------------------------------------------------------------------------

IMAGE_URL="${DEBIAN_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest}"
IMAGE_ORIGINAL_FILE_NAME="${DEBIAN_IMAGE_ORIGINAL_FILE_NAME:-debian-13-generic-amd64.qcow2}"
IMAGE_UPDATED_FILE_NAME="${DEBIAN_EFFECTIVE_IMAGE_TO_USE:-${IMAGE_ORIGINAL_FILE_NAME}--updated.qcow2}"

IMAGE_DIR="/var/lib/libvirt/images/iso"
IMAGE_ORIGINAL="${IMAGE_DIR}/${IMAGE_ORIGINAL_FILE_NAME}"
IMAGE_UPDATED="${IMAGE_DIR}/${IMAGE_UPDATED_FILE_NAME}"

sudo mkdir -p "${IMAGE_DIR}"

# ------------------------------------------------------------------------------
# 1. Download if not already present
# ------------------------------------------------------------------------------

if [[ ! -f "${IMAGE_ORIGINAL}" ]]; then
    echo "==> Downloading ${IMAGE_ORIGINAL_FILE_NAME}"
    wget -O "${IMAGE_ORIGINAL_FILE_NAME}" "${IMAGE_URL}/${IMAGE_ORIGINAL_FILE_NAME}"
    sudo mv "./${IMAGE_ORIGINAL_FILE_NAME}" "${IMAGE_DIR}/"
else
    echo "==> Image already present: ${IMAGE_ORIGINAL}"
fi

# ------------------------------------------------------------------------------
# 2. Copy and expand to 4G
#    The generic image is ~3G virtual. 4G gives apt upgrade enough room.
#    Individual VMs are resized further by 09-create-demo-vms-*.sh.
# ------------------------------------------------------------------------------

echo "==> Copying original -> updated"
sudo cp "${IMAGE_ORIGINAL}" "${IMAGE_UPDATED}"

echo "==> Expanding to 4G with virt-resize (rewrites GPT partition table)"
WORK="${IMAGE_DIR}/debian-resize-work.qcow2"
sudo rm -f "${WORK}"
sudo qemu-img create -f qcow2 "${WORK}" 4G
sudo virt-resize --expand /dev/sda1 "${IMAGE_UPDATED}" "${WORK}"
sudo mv "${WORK}" "${IMAGE_UPDATED}"

# ------------------------------------------------------------------------------
# 3. apt upgrade
# ------------------------------------------------------------------------------

echo "==> Running apt upgrade"
sudo virt-customize \
    -a "${IMAGE_UPDATED}" \
    --update \
    --run-command "apt-get upgrade -y -q" \
    --run-command "apt-get clean" \
    --run-command "rm -rf /var/lib/apt/lists/*"

# ------------------------------------------------------------------------------
# 4. GRUB serial console patch
#
# The generic image targets environments with a VGA console. KVM VMs with
# --graphics none have no VGA device -- GRUB's gfxterm and video modules
# hang indefinitely when no display is found.
#
# We rewrite /etc/default/grub, regenerate grub.cfg via update-grub, then
# scrub remaining video/gfx references that update-grub re-adds from
# /etc/grub.d/ scripts.
# ------------------------------------------------------------------------------

echo "==> Patching GRUB for serial console (no gfx)"
sudo virt-customize \
    -a "${IMAGE_UPDATED}" \
    --write '/etc/default/grub:GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR=Debian
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
' \
    --run-command "update-grub" \
    --run-command "sed -i \
        -e 's/terminal_output.*/terminal_output serial/' \
        -e '/insmod gfxterm/d' \
        -e '/insmod all_video/d' \
        -e '/insmod video_bochs/d' \
        -e '/insmod video_cirrus/d' \
        -e '/set gfxmode/d' \
        -e '/set gfxpayload/d' \
        -e '/load_video/d' \
        -e '/linux_gfx_mode/d' \
        -e '/feature_all_video_module/d' \
        -e '/function gfxmode/,/^}/d' \
        -e 's/set timeout=0/set timeout=1/' \
        -e 's/set timeout=30/set timeout=1/' \
        -e 's/set timeout_style=menu/set timeout_style=countdown/' \
        /boot/grub/grub.cfg"

# ------------------------------------------------------------------------------
# 5. cloud-init prerequisites
#    machine-id: must be empty so each cloned VM generates its own at boot
#    systemd-firstboot: masked so cloud-init owns first-boot configuration
#                       (firstboot prompts interactively and blocks cloud-init)
# ------------------------------------------------------------------------------

echo "==> Preparing for cloud-init"
sudo virt-customize \
    -a "${IMAGE_UPDATED}" \
    --run-command "truncate -s 0 /etc/machine-id" \
    --run-command "systemctl mask systemd-firstboot.service"

# ------------------------------------------------------------------------------
# 6. Verify
# ------------------------------------------------------------------------------

echo ""
echo "==> Verifying grub.cfg -- expect: terminal_output serial, timeout=1, no gfx"
sudo virt-cat "${IMAGE_UPDATED}" /boot/grub/grub.cfg \
    | grep -E "terminal|timeout|gfx|video" || true

echo ""
echo "================================================================"
echo "  Done: ${IMAGE_UPDATED}"
echo ""
echo "  To sync to the other site:"
echo "    scp ${IMAGE_UPDATED} lab@<other-site-host>:${IMAGE_DIR}/"
echo ""
echo "  Next step: bash 09-create-demo-vms-debian.sh"
echo "================================================================"
