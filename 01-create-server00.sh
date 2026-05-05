#!/bin/bash
# 01-create-server00.sh -- Build a Debian 13 preseed ISO for bare metal install
#
# Produces a bootable ISO that installs Debian 13 unattended on the target host.
# Run on Linux (requires xorriso).
#
# Usage:
#   source site-A.env && source site-A-secrets.env && bash 01-create-server00.sh
#   source site-B.env && source site-B-secrets.env && bash 01-create-server00.sh

set -euo pipefail

for VAR in SITE_NAME PRESEED_WIRELESS_WPA PRESEED_WIRELESS_ESSID \
           PRESEED_HOSTNAME PRESEED_DOMAIN PRESEED_IF_LAN \
           PRESEED_IP PRESEED_NETMASK PRESEED_GW \
           LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        exit 1
    fi
done

NETINST_ISO="debian-13.4.0-amd64-netinst.iso"
NETINST_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
TMPL_FILE="preseed.cfg.tmpl.debian13.amd64.wifi.GMKtec"
OUTPUT_ISO="debian-13-preseed-amd64-${SITE_NAME}.iso"
WORK_DIR="/tmp/debian-preseed-build-${SITE_NAME}"

echo "=== 01-create-server00.sh -- site: ${SITE_NAME} ==="

for cmd in xorriso curl sed dd wget; do
    command -v "$cmd" &>/dev/null \
        || { echo "ERROR: $cmd not found -- sudo apt install xorriso curl wget"; exit 1; }
done

[[ -f "${TMPL_FILE}" ]] || { echo "ERROR: ${TMPL_FILE} not found"; exit 1; }

# -- Download netinst ISO ------------------------------------------------------
if [[ ! -f "${NETINST_ISO}" ]]; then
    echo "==> Downloading Debian 13 netinst ISO"
    wget "${NETINST_URL}/${NETINST_ISO}"
else
    echo "==> ISO already present: ${NETINST_ISO}"
fi

# -- Extract ISO ---------------------------------------------------------------
echo "==> Extracting ISO"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
xorriso -osirrox on -indev "${NETINST_ISO}" -extract / "${WORK_DIR}" 2>/dev/null
chmod -R u+w "${WORK_DIR}"

# -- Substitute placeholders in preseed template -------------------------------
echo "==> Generating preseed.cfg"

_escape() { printf '%s' "$1" | sed 's/[\\/&]/\\&/g'; }

PRESEED_OUT="${WORK_DIR}/preseed.cfg"
cp "${TMPL_FILE}" "${PRESEED_OUT}"

sed -i "s|%%PRESEED_HOSTNAME%%|$(_escape "${PRESEED_HOSTNAME}")|g"         "${PRESEED_OUT}"
sed -i "s|%%PRESEED_DOMAIN%%|$(_escape "${PRESEED_DOMAIN}")|g"             "${PRESEED_OUT}"
sed -i "s|%%PRESEED_IF_LAN%%|$(_escape "${PRESEED_IF_LAN}")|g"             "${PRESEED_OUT}"
sed -i "s|%%PRESEED_IP%%|$(_escape "${PRESEED_IP}")|g"                     "${PRESEED_OUT}"
sed -i "s|%%PRESEED_NETMASK%%|$(_escape "${PRESEED_NETMASK}")|g"           "${PRESEED_OUT}"
sed -i "s|%%PRESEED_GW%%|$(_escape "${PRESEED_GW}")|g"                     "${PRESEED_OUT}"
sed -i "s|%%PRESEED_WIRELESS_ESSID%%|$(_escape "${PRESEED_WIRELESS_ESSID}")|g" "${PRESEED_OUT}"
sed -i "s|%%PRESEED_WIRELESS_WPA%%|$(_escape "${PRESEED_WIRELESS_WPA}")|g"     "${PRESEED_OUT}"
sed -i "s|%%LAB_SSH_PUBKEY%%|$(_escape "${LAB_SSH_PUBKEY}")|g"             "${PRESEED_OUT}"
sed -i "s|%%LAB_PASSWORD%%|$(_escape "${LAB_PASSWORD}")|g"                 "${PRESEED_OUT}"
sed -i "s|%%ROOT_PASSWORD%%|$(_escape "${ROOT_PASSWORD}")|g"               "${PRESEED_OUT}"

# -- Patch boot loaders for unattended install ---------------------------------
echo "==> Patching boot loaders"

# GRUB (EFI -- standard on GMKtec and modern hardware)
GRUB_CFG="${WORK_DIR}/boot/grub/grub.cfg"
if [[ -f "${GRUB_CFG}" ]]; then
    sed -i 's/set timeout=.*/set timeout=1/' "${GRUB_CFG}"
    sed -i 's/set default=.*/set default=1/' "${GRUB_CFG}"
    sed -i 's|linux.*/install.amd/vmlinuz|& auto=true priority=critical file=/cdrom/preseed.cfg|' "${GRUB_CFG}"
fi

# ISOLINUX (legacy BIOS fallback)
ISOLINUX_CFG="${WORK_DIR}/isolinux/isolinux.cfg"
TXT_CFG="${WORK_DIR}/isolinux/txt.cfg"
if [[ -f "${TXT_CFG}" ]]; then
    sed -i 's|^default .*|default install|' "${ISOLINUX_CFG}" 2>/dev/null || true
    sed -i 's|append.*|& auto=true priority=critical file=/cdrom/preseed.cfg|' "${TXT_CFG}"
fi

# -- Extract MBR for hybrid ISO ------------------------------------------------
echo "==> Extracting boot headers"
dd if="${NETINST_ISO}" bs=1 count=432 of="${WORK_DIR}/isohdpfx.bin" 2>/dev/null

# -- Repackage as hybrid EFI/BIOS ISO ------------------------------------------
echo "==> Creating ${OUTPUT_ISO}"
xorriso -as mkisofs \
    -r -V "DB13-PRE-${SITE_NAME}" \
    -J -joliet-long \
    -isohybrid-mbr "${WORK_DIR}/isohdpfx.bin" \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    -o "${OUTPUT_ISO}" \
    "${WORK_DIR}"

echo "=== SUCCESS: ${OUTPUT_ISO} is ready ==="
echo "    Write to USB: dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
