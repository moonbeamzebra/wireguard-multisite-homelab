#!/bin/bash
# 14-handbrake-teardown.sh -- Remove all HandBrake traces from m-server00
#
# Removes everything installed by 13-handbrake-setup.sh.
# Does NOT touch /mnt/handbrake-out (your ripped files).
#
# Usage:
#   sudo bash 14-handbrake-teardown.sh

set -euo pipefail

[[ "${EUID}" -ne 0 ]] && { echo "ERROR: run as root: sudo bash $0"; exit 1; }

echo "================================================================"
echo "  [14-handbrake-teardown] Remove HandBrake from m-server00"
echo "================================================================"
echo ""

# ------------------------------------------------------------------------------
# 1. Packages
# ------------------------------------------------------------------------------
echo "==> [1/3] Remove packages"

PKGS=(
    handbrake-cli
    lsdvd
    libdvdread-dev
    libdvdnav4
    vainfo
    mesa-va-drivers
    libva-drm2
    build-essential
    libtool
    autoconf
    automake
)

for pkg in "${PKGS[@]}"; do
    if dpkg -l "${pkg}" 2>/dev/null | grep -q "^ii"; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "${pkg}" 2>/dev/null \
            && echo "    removed : ${pkg}" || true
    fi
done

apt-get autoremove -y --purge 2>/dev/null | grep -E "^Removing" || true
apt-get clean
echo "    packages: done"

# ------------------------------------------------------------------------------
# 2. libdvdcss (built from source -- no dpkg record)
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/3] Remove libdvdcss (built from source)"

rm -f  /usr/lib/x86_64-linux-gnu/libdvdcss*
rm -f  /usr/lib/x86_64-linux-gnu/pkgconfig/libdvdcss.pc
rm -f  /usr/include/dvdcss
rm -rf /usr/include/dvdcss
ldconfig
echo "    libdvdcss: removed"

# ------------------------------------------------------------------------------
# 3. Scripts
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/3] Remove scripts"

rm -f /usr/local/bin/rip-dvd.sh
echo "    /usr/local/bin/rip-dvd.sh: removed"

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  [14-handbrake-teardown] Complete"
echo "  All HandBrake traces removed from m-server00."
echo "  Your files in /mnt/handbrake-out are untouched."
echo "================================================================"
