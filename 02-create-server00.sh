#!/bin/bash
# 02-create-server00.sh -- Build Debian 12 preseed ISO for server00
# Run on: MAC INTEL
#
# Run in the same folder as the site env files.
# Prerequisites:
#   brew install xorriso
#   brew install gnu-sed   # available as gsed or aliased as sed
#
# Usage:
#   source site-A.env && source secrets-A.env && bash 02-create-server00.sh
#   source site-B.env && source secrets-B.env && bash 02-create-server00.sh
#
# Required env vars (from site-*.env + secrets-*.env):
#   SITE_NAME, SERVER00_HOSTNAME, PRESEED_HOSTNAME, PRESEED_DOMAIN
#   IF_LAN, PRESEED_IP, PRESEED_NETMASK, PRESEED_GW
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD

set -euo pipefail

# -- Validate required variables -----------------------------------------------
for VAR in SITE_NAME PRESEED_HOSTNAME PRESEED_DOMAIN IF_LAN PRESEED_IP PRESEED_NETMASK PRESEED_GW LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "Usage: source site-A.env && source secrets-A.env && bash 02-create-server00.sh"
        exit 1
    fi
done

NETINST_ISO="debian-12.10.0-amd64-netinst.iso"
NETINST_URL="https://cdimage.debian.org/cdimage/archive/12.10.0/amd64/iso-cd/${NETINST_ISO}"
TMPL_FILE="preseed.cfg.tmpl"
OUTPUT_ISO="debian-12-preseed-${SITE_NAME}.iso"
WORK_DIR="/tmp/debian-preseed-build-${SITE_NAME}"

echo "=== 02-create-server00.sh -- site: ${SITE_NAME} ==="

# -- Check prerequisites -------------------------------------------------------
if ! command -v xorriso &>/dev/null; then
    echo "ERROR: xorriso not found. Install with: brew install xorriso"
    exit 1
fi

# Support both gsed (brew install gnu-sed) and sed (if GNU sed is default)
if command -v gsed &>/dev/null; then
    SED=gsed
else
    SED=sed
fi

if [[ ! -f "${TMPL_FILE}" ]]; then
    echo "ERROR: ${TMPL_FILE} not found in current directory"
    exit 1
fi

# -- Download the Debian netinst ISO if not present ----------------------------
if [[ ! -f "${NETINST_ISO}" ]]; then
    echo "=== Downloading ${NETINST_ISO} ==="
    curl -O -L "${NETINST_URL}"
else
    echo "=== ISO already present: ${NETINST_ISO} ==="
fi

# -- Extract the ISO -----------------------------------------------------------
echo "=== Extracting ISO ==="
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
xorriso -osirrox on \
    -indev "${NETINST_ISO}" \
    -extract / "${WORK_DIR}" 2>/dev/null

chmod -R u+w "${WORK_DIR}"

# -- Substitute placeholders in the template -> preseed.cfg --------------------
echo "=== Generating preseed.cfg from template ==="

# Escape values for use in sed replacement (handle slashes and newlines)
_escape() { printf '%s' "$1" | ${SED} 's/[\/&]/\\&/g'; }

PRESEED_OUT="${WORK_DIR}/preseed.cfg"
cp "${TMPL_FILE}" "${PRESEED_OUT}"

${SED} -i "s|%%PRESEED_HOSTNAME%%|$(_escape "${PRESEED_HOSTNAME}")|g" "${PRESEED_OUT}"
${SED} -i "s|%%PRESEED_DOMAIN%%|$(_escape "${PRESEED_DOMAIN}")|g"     "${PRESEED_OUT}"
${SED} -i "s|%%IF_LAN%%|$(_escape "${IF_LAN}")|g"                     "${PRESEED_OUT}"
${SED} -i "s|%%PRESEED_IP%%|$(_escape "${PRESEED_IP}")|g"             "${PRESEED_OUT}"
${SED} -i "s|%%PRESEED_NETMASK%%|$(_escape "${PRESEED_NETMASK}")|g"   "${PRESEED_OUT}"
${SED} -i "s|%%PRESEED_GW%%|$(_escape "${PRESEED_GW}")|g"             "${PRESEED_OUT}"
${SED} -i "s|%%LAB_SSH_PUBKEY%%|$(_escape "${LAB_SSH_PUBKEY}")|g"     "${PRESEED_OUT}"
${SED} -i "s|%%LAB_PASSWORD%%|$(_escape "${LAB_PASSWORD}")|g"         "${PRESEED_OUT}"
${SED} -i "s|%%ROOT_PASSWORD%%|$(_escape "${ROOT_PASSWORD}")|g"       "${PRESEED_OUT}"

echo "--- preseed.cfg generated ---"

# -- Patch boot loaders to auto-select preseed ---------------------------------
echo "=== Patching boot loaders ==="

GRUB_CFG="${WORK_DIR}/boot/grub/grub.cfg"
if [[ -f "${GRUB_CFG}" ]]; then
    ${SED} -i 's/set timeout=.*/set timeout=5/' "${GRUB_CFG}"
    # Set text install as default menu entry (entry 0 = graphical, 1 = text install)
    ${SED} -i 's/set default=.*/set default=1/' "${GRUB_CFG}"
    ${SED} -i 's|linux.*/install.amd/vmlinuz|& auto=true priority=critical file=/cdrom/preseed.cfg|' "${GRUB_CFG}"
    echo "--- grub.cfg patched (text install set as default) ---"
fi

ISOLINUX_CFG="${WORK_DIR}/isolinux/isolinux.cfg"
ISOLINUX_TXT="${WORK_DIR}/isolinux/txt.cfg"
if [[ -f "${ISOLINUX_TXT}" ]]; then
    ${SED} -i 's|append.*|& auto=true priority=critical file=/cdrom/preseed.cfg|' "${ISOLINUX_TXT}"
    ${SED} -i 's/timeout .*/timeout 50/' "${ISOLINUX_CFG}" 2>/dev/null || true
    # Set text install as default (label install = text, label installgui = graphical)
    ${SED} -i 's/^default .*/default install/' "${ISOLINUX_CFG}" 2>/dev/null || true
    echo "--- isolinux.cfg patched (text install set as default) ---"
fi

# -- Extract MBR from original ISO ---------------------------------------------
echo "=== Extracting MBR ==="
dd if="${NETINST_ISO}" bs=1 count=432 of="${WORK_DIR}/isohdpfx.bin" 2>/dev/null

# -- Repackage the ISO ---------------------------------------------------------
echo "=== Creating ${OUTPUT_ISO} ==="
xorriso -as mkisofs \
    -r \
    -V "Debian12Preseed${SITE_NAME}" \
    -J \
    -joliet-long \
    -isohybrid-mbr "${WORK_DIR}/isohdpfx.bin" \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "${OUTPUT_ISO}" \
    "${WORK_DIR}"

echo ""
echo "=== SUCCESS ==="
echo "ISO created : ${OUTPUT_ISO}"
echo "Size        : $(du -sh ${OUTPUT_ISO} | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Create a new VM in VMware Fusion:"
echo "       OS: Debian 12 64-bit"
echo "       Disk: 100G    RAM: 6G    CPU: 2"
echo "       Adapter 1: ${IF_LAN} -> ${VNET_LAN:-vmnet6/vmnet7}  (LAN)"
echo "       Adapter 2: ${IF_ISP} -> ${VNET_ISP:-vmnet3/vmnet10} (ISP)"
echo "       Adapter 3: ${IF_MGMT_ACCESS:-ens35} -> bridged Wi-Fi         (management)"
echo "  2. Attach ${OUTPUT_ISO} as CD/DVD"
echo "  3. Boot -- fully automated install (~10 min)"
echo "  4. Detach ISO after reboot"
echo "  5. ssh lab@${PRESEED_IP}"
echo "  6. scp scripts to host, then:"
echo "       sudo bash 03-packages.sh"
echo "       source site-A.env && source secrets-A.env"
echo "       sudo -E bash 04-network.sh && sudo netplan apply"
echo "       sudo bash 05-libvirt-nets.sh"
echo "       sudo bash 06-libvirt-config.sh"
