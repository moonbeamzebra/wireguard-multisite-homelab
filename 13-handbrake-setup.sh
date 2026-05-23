#!/bin/bash
# 13-handbrake-setup.sh -- Install HandBrakeCLI directly on m-server00 (no LXC)
#
# Standalone: assumes nothing has been installed before.
# Teardown:   sudo bash 14-handbrake-teardown.sh
#
# Usage:
#   sudo -E bash 13-handbrake-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/site-A.env" ]] && source "${SCRIPT_DIR}/site-A.env"

OUTPUT_DIR="${OUTPUT_DIR:-/mnt/handbrake-out}"
JELLYFIN_HOST="${JELLYFIN_HOST:-c-jellyfin}"
JELLYFIN_MEDIA="${JELLYFIN_MEDIA:-/media/mybook/Movies}"

[[ "${EUID}" -ne 0 ]] && { echo "ERROR: run as root: sudo -E bash $0"; exit 1; }

echo "================================================================"
echo "  [13-handbrake-setup] HandBrake on m-server00 (host-direct)"
echo "  Output : ${OUTPUT_DIR}"
echo "================================================================"
echo ""

# ------------------------------------------------------------------------------
# 1. Repos -- add contrib and non-free (needed for handbrake-cli, libdvdcss)
# ------------------------------------------------------------------------------
echo "==> [1/5] Configure apt repos (contrib + non-free for Trixie)"

# Detect release
RELEASE=$(grep "^deb " /etc/apt/sources.list | head -1 | awk '{print $3}' | cut -d/ -f1)
echo "    Detected release: ${RELEASE}"

# Rewrite sources.list with contrib + non-free added
cat > /etc/apt/sources.list << SRCEOF
deb http://deb.debian.org/debian/ ${RELEASE} main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ ${RELEASE} main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ ${RELEASE}-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ ${RELEASE}-updates main contrib non-free non-free-firmware
SRCEOF

apt-get update -qq
echo "    repos: OK"

# ------------------------------------------------------------------------------
# 2. Packages
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/5] Install packages"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    handbrake-cli \
    lsdvd \
    libdvdread-dev \
    libdvdnav4 \
    vainfo \
    mesa-va-drivers \
    libva-drm2 \
    wget \
    build-essential \
    libtool \
    autoconf \
    automake

echo "    packages: OK"

# ------------------------------------------------------------------------------
# 3. libdvdcss -- build from source (not in Trixie repos)
#    libdvdcss is needed to decrypt CSS-encrypted commercial DVDs.
#    Source: videolan.org (the official upstream)
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/5] Build and install libdvdcss from source"

DVDCSS_VERSION="1.4.3"
DVDCSS_URL="https://download.videolan.org/pub/libdvdcss/${DVDCSS_VERSION}/libdvdcss-${DVDCSS_VERSION}.tar.bz2"
BUILD_DIR="/tmp/libdvdcss-build"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

echo "    Downloading libdvdcss ${DVDCSS_VERSION}..."
wget -q "${DVDCSS_URL}" -O libdvdcss.tar.bz2
tar xjf libdvdcss.tar.bz2
cd "libdvdcss-${DVDCSS_VERSION}"

echo "    Configuring..."
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --disable-static 2>/dev/null

echo "    Building..."
make -j"$(nproc)" 2>/dev/null

echo "    Installing..."
make install 2>/dev/null
ldconfig

cd /
rm -rf "${BUILD_DIR}"
echo "    libdvdcss ${DVDCSS_VERSION}: OK"

# ------------------------------------------------------------------------------
# 4. Output directory
# ------------------------------------------------------------------------------
echo ""
echo "==> [4/5] Output directory: ${OUTPUT_DIR}"

mkdir -p "${OUTPUT_DIR}"
chown root:users "${OUTPUT_DIR}"
chmod 775 "${OUTPUT_DIR}"
echo "    ${OUTPUT_DIR}: OK"

# ------------------------------------------------------------------------------
# 5. rip-dvd.sh
# ------------------------------------------------------------------------------
echo ""
echo "==> [5/5] Install /usr/local/bin/rip-dvd.sh"

cat > /usr/local/bin/rip-dvd.sh << RIPEOF
#!/bin/bash
# rip-dvd.sh -- Rip a DVD to H264 MP4 using HandBrakeCLI
#
# Usage:
#   rip-dvd.sh "Movie Title"
#   rip-dvd.sh --scan                     # inspect titles/tracks
#   rip-dvd.sh --title 1 "Movie Title"    # force title number
#   rip-dvd.sh --quality 18 "Movie Title" # higher quality (larger file)
#   rip-dvd.sh --no-vaapi "Movie Title"   # CPU encoding (GPU fallback)
#
# Output : ${OUTPUT_DIR}/<Movie_Title>.mp4
# Audio  : English, French, Spanish kept
# Subs   : English, French, Spanish (soft, selectable)
# Format : H264 High, AAC 160k, MP4 (Jellyfin/AppleTV/Chromecast compatible)

set -euo pipefail

DRIVE="/dev/sr0"
OUTPUT_DIR="${OUTPUT_DIR}"
QUALITY=20
DVD_TITLE=""
SCAN_ONLY=false
USE_VAAPI=true
MOVIE_TITLE=""
KEEP_LANGS="eng,fre,spa"

usage() {
    cat << 'USAGE'
Usage: rip-dvd.sh [OPTIONS] "Movie Title"

Options:
  --quality N    RF quality (default 20; lower = better/larger; range 18-24)
  --title N      Force DVD title number (default: auto main feature)
  --no-vaapi     CPU encoding (x264) -- slower, use if GPU fails
  --scan         Show DVD titles/audio/subtitle tracks then exit
  --help         This help

Examples:
  rip-dvd.sh --scan
  rip-dvd.sh "Alien 1979"
  rip-dvd.sh --quality 18 "Blade Runner"
  rip-dvd.sh --title 2 "Concert DVD"
  rip-dvd.sh --no-vaapi "Alien 1979"
USAGE
    exit 0
}

while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --quality)  QUALITY="\$2";   shift 2 ;;
        --title)    DVD_TITLE="\$2"; shift 2 ;;
        --no-vaapi) USE_VAAPI=false; shift ;;
        --scan)     SCAN_ONLY=true;  shift ;;
        --help|-h)  usage ;;
        -*)         echo "ERROR: Unknown option: \$1"; usage ;;
        *)          MOVIE_TITLE="\$1"; shift ;;
    esac
done

if [[ "\${SCAN_ONLY}" == "true" ]]; then
    echo "==> Scanning DVD in \${DRIVE} ..."
    HandBrakeCLI --input "\${DRIVE}" --title 0 --scan 2>&1 | \
        grep -E "^\s*\+ (title|duration|audio|subtitle|angle|chapters)" || true
    echo ""
    echo "--- lsdvd ---"
    lsdvd "\${DRIVE}" 2>/dev/null || echo "(lsdvd not available)"
    exit 0
fi

[[ -z "\${MOVIE_TITLE}" ]] && { echo "ERROR: Movie title required"; echo "Usage: rip-dvd.sh \"Movie Title\""; exit 1; }
[[ ! -e "\${DRIVE}" ]]    && { echo "ERROR: \${DRIVE} not found -- optical drive absent?"; exit 1; }

OUTPUT_FILENAME="\$(echo "\${MOVIE_TITLE}" | tr ' ' '_' | tr -d '/:*?"<>|')"
OUTPUT_FILE="\${OUTPUT_DIR}/\${OUTPUT_FILENAME}.mp4"
mkdir -p "\${OUTPUT_DIR}"

# Available encoders on this system: x264, x264_10bit (VA-API not compiled in)
# AMD Radeon 680M has VA-API H264 but HandBrakeCLI build doesn't include vce/vaapi encoders
ENCODER_LABEL="x264 CPU"
ENCODER_OPTS=(--encoder "x264" --quality "\${QUALITY}" --encoder-preset "slow" --encoder-profile "high")
HW_DECODE=""

echo "================================================================"
echo "  rip-dvd.sh"
echo "  Movie   : \${MOVIE_TITLE}"
echo "  Output  : \${OUTPUT_FILE}"
echo "  Encoder : \${ENCODER_LABEL}  |  Quality RF \${QUALITY}"
echo "================================================================"
echo ""

START=\$(date +%s)

if HandBrakeCLI \
    --input  "\${DRIVE}" \
    --output "\${OUTPUT_FILE}" \
    "\${TITLE_ARGS[@]}" \
    "\${ENCODER_OPTS[@]}" \
    --format             "av_mp4" \
    --optimize \
    --markers \
    --audio-lang-list    "\${KEEP_LANGS}" \
    --all-audio \
    --aencoder           "av_aac" \
    --ab                 "160" \
    --mixdown            "dpl2" \
    --subtitle-lang-list "\${KEEP_LANGS}" \
    --all-subtitles; then

    ELAPSED=\$(( \$(date +%s) - START ))
    echo ""
    echo "================================================================"
    echo "  Done!  \${OUTPUT_FILE}"
    echo "  Size : \$(du -sh "\${OUTPUT_FILE}" 2>/dev/null | cut -f1)"
    echo "  Time : \$(( ELAPSED/60 ))m \$(( ELAPSED%60 ))s"
    echo ""
    echo "  Copy to Jellyfin:"
    echo "    scp '\${OUTPUT_FILE}' lab@${JELLYFIN_HOST}:${JELLYFIN_MEDIA}/"
    echo "================================================================"
else
    echo ""
    echo "ERROR: HandBrakeCLI failed -- see output above"
    rm -f "\${OUTPUT_FILE}"
    exit 1
fi
RIPEOF

chmod 755 /usr/local/bin/rip-dvd.sh
echo "    /usr/local/bin/rip-dvd.sh: OK"

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  [13-handbrake-setup] Complete"
echo ""
echo "  rip-dvd.sh --scan"
echo "  rip-dvd.sh \"Movie Title\""
echo "  rip-dvd.sh --no-vaapi \"Movie Title\"   # if GPU fails"
echo ""
echo "  Teardown: sudo bash 14-handbrake-teardown.sh"
echo "================================================================"
