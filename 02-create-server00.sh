#!/bin/bash
# 02-create-server00.sh -- Build Debian 13 preseed ISO for server00
# Run on: LINUX (Debian/Ubuntu)
#
# Usage:
#   source site-A.env && source secrets-A.env && bash 02-create-server00.sh

set -euo pipefail

# -- Validate required variables -----------------------------------------------
for VAR in SITE_NAME PRESEED_HOSTNAME PRESEED_DOMAIN IF_LAN PRESEED_IP PRESEED_NETMASK PRESEED_GW LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        exit 1
    fi
done

# -- Configuration Debian 13 (Trixie) ------------------------------------------
NETINST_ISO="debian-13.4.0-amd64-netinst.iso"
NETINST_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"


TMPL_FILE="preseed.cfg.tmpl.debian13.amd64"
OUTPUT_ISO="debian-13-preseed-amd64-${SITE_NAME}.iso"
WORK_DIR="/tmp/debian-preseed-build-${SITE_NAME}"

echo "=== 02-create-server00.sh -- site: ${SITE_NAME} ==="

# -- Check prerequisites (Linux specific) --------------------------------------
PREREQS=(xorriso curl sed dd)
for cmd in "${PREREQS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Install with: sudo apt update && sudo apt install xorriso curl"
        exit 1
    fi
done

if [[ ! -f "${TMPL_FILE}" ]]; then
    echo "ERROR: ${TMPL_FILE} not found"
    exit 1
fi

# -- Download the Debian netinst ISO if not present ----------------------------
if [[ ! -f "${NETINST_ISO}" ]]; then
    echo "=== Downloading Debian 13 netinst ISO ==="
    #curl -L -o "${NETINST_ISO}" "${NETINST_URL}"
    wget "${NETINST_URL}/${NETINST_ISO}"
else
    echo "=== ISO already present: ${NETINST_ISO} ==="
fi

# -- Extract the ISO -----------------------------------------------------------
echo "=== Extracting ISO ==="
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Utilisation de xorriso pour extraire proprement l'image
xorriso -osirrox on -indev "${NETINST_ISO}" -extract / "${WORK_DIR}" 2>/dev/null
chmod -R u+w "${WORK_DIR}"

# -- Substitute placeholders ---------------------------------------------------
echo "=== Generating preseed.cfg from template ==="

_escape() { printf '%s' "$1" | sed 's/[\/&]/\\&/g'; }

PRESEED_OUT="${WORK_DIR}/preseed.cfg"
cp "${TMPL_FILE}" "${PRESEED_OUT}"

# Utilisation directe de sed (GNU sed par défaut sur Linux)
sed -i "s|%%PRESEED_HOSTNAME%%|$(_escape "${PRESEED_HOSTNAME}")|g" "${PRESEED_OUT}"
sed -i "s|%%PRESEED_DOMAIN%%|$(_escape "${PRESEED_DOMAIN}")|g"     "${PRESEED_OUT}"
sed -i "s|%%IF_LAN%%|$(_escape "${IF_LAN}")|g"                     "${PRESEED_OUT}"
sed -i "s|%%PRESEED_IP%%|$(_escape "${PRESEED_IP}")|g"             "${PRESEED_OUT}"
sed -i "s|%%PRESEED_NETMASK%%|$(_escape "${PRESEED_NETMASK}")|g"   "${PRESEED_OUT}"
sed -i "s|%%PRESEED_GW%%|$(_escape "${PRESEED_GW}")|g"             "${PRESEED_OUT}"
sed -i "s|%%LAB_SSH_PUBKEY%%|$(_escape "${LAB_SSH_PUBKEY}")|g"     "${PRESEED_OUT}"
sed -i "s|%%LAB_PASSWORD%%|$(_escape "${LAB_PASSWORD}")|g"         "${PRESEED_OUT}"
sed -i "s|%%ROOT_PASSWORD%%|$(_escape "${ROOT_PASSWORD}")|g"       "${PRESEED_OUT}"

# -- Patch boot loaders (Auto-boot preseed) ------------------------------------
echo "=== Patching boot loaders for Automation ==="

# 1. GRUB (Pour le boot EFI - standard sur les Mini-PCs modernes)
GRUB_CFG="${WORK_DIR}/boot/grub/grub.cfg"
if [[ -f "${GRUB_CFG}" ]]; then
    sed -i 's/set timeout=.*/set timeout=1/' "${GRUB_CFG}"
    sed -i 's/set default=.*/set default=1/' "${GRUB_CFG}"
    # Ajout des paramètres de preseed à la ligne linux du menu install
    sed -i 's|linux.*/install.amd/vmlinuz|& auto=true priority=critical file=/cdrom/preseed.cfg|' "${GRUB_CFG}"
fi

# 2. ISOLINUX (Pour le boot BIOS legacy)
ISOLINUX_CFG="${WORK_DIR}/isolinux/isolinux.cfg"
TXT_CFG="${WORK_DIR}/isolinux/txt.cfg"
if [[ -f "${TXT_CFG}" ]]; then
    sed -i 's|^default .*|default install|' "${ISOLINUX_CFG}" 2>/dev/null || true
    sed -i 's|append.*|& auto=true priority=critical file=/cdrom/preseed.cfg|' "${TXT_CFG}"
fi

# -- Extract MBR and EFI artifacts ---------------------------------------------
echo "=== Extracting Boot Headers ==="
dd if="${NETINST_ISO}" bs=1 count=432 of="${WORK_DIR}/isohdpfx.bin" 2>/dev/null

# -- Repackage the ISO (Hybride EFI/BIOS) --------------------------------------
echo "=== Creating ${OUTPUT_ISO} ==="
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
