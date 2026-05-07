#!/bin/bash
# 15-create-jellyfin-lxc.sh -- Deploy the Jellyfin LXC container on c-server00
#
# Creates a Debian 13 LXC container managed by libvirt (virsh -c lxc:///).
# The container:
#   - Runs on LAN10 (10.1.10.10) via the existing lan-ext10 / br-ext10 network
#     (infra subnet -- appropriate for a media server, keeps OVS portgroups intact)
#   - Gets /dev/dri/card0 and /dev/dri/renderD128 via <hostdev> passthrough
#     (supported for LXC domains, unlike KVM -- no VFIO needed)
#   - Mounts /mnt/mybook from the host as /media/mybook (bind mount in XML)
#   - Has Jellyfin installed and configured for VA-API (AMD Radeon 680M RDNA2)
#
# Upgrade path: bash 14-jellyfin-host-teardown.sh && bash 15-create-jellyfin-lxc.sh
#
# Usage:
#   source site-B.env && source site-B-secrets.env
#   sudo -E bash 15-create-jellyfin-lxc.sh
#
# Required env vars:
#   SITE_NAME  SITE_LETTER  LAB_SSH_PUBKEY  LAB_PASSWORD  ROOT_PASSWORD

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root: sudo -E bash $0"
    exit 1
fi

for VAR in SITE_NAME SITE_LETTER LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "       Run: source site-B.env && source site-B-secrets.env && sudo -E bash $0"
        exit 1
    fi
done

if [[ "${SITE_LETTER}" != "c" ]]; then
    echo "ERROR: this script is for site B (chalet) only -- SITE_LETTER=${SITE_LETTER}"
    exit 1
fi

MYBOOK_MOUNT="/mnt/mybook"
if ! mountpoint -q "${MYBOOK_MOUNT}"; then
    echo "ERROR: ${MYBOOK_MOUNT} is not mounted."
    echo "       Run 13-jellyfin-host-setup.sh first (and plug in the WD MyBook)."
    exit 1
fi

if [[ ! -d /dev/dri ]]; then
    echo "ERROR: /dev/dri not found -- run 13-jellyfin-host-setup.sh first."
    exit 1
fi

# ------------------------------------------------------------------------------
# Parameters
# ------------------------------------------------------------------------------

VM_NAME="c-jellyfin"
JELLYFIN_IP="10.1.10.10"
NETWORK="lan-ext10"
PORTGROUP="lan10"
ROOTFS="/var/lib/libvirt/filesystems/${VM_NAME}"

HASH=$(echo -n "${SITE_NAME}::${VM_NAME}" | md5sum | awk '{print $1}')
MAC_ADDRESS="52:54:${HASH:0:2}:${HASH:2:2}:${HASH:4:2}:${HASH:6:2}"

DRI_DEVICES=()
for dev in /dev/dri/card* /dev/dri/renderD*; do
    [[ -e "${dev}" ]] && DRI_DEVICES+=("${dev}")
done

echo "=== [15-create-jellyfin-lxc] Start ==="
echo "    Container : ${VM_NAME}"
echo "    Network   : ${NETWORK} / ${PORTGROUP}  IP: ${JELLYFIN_IP}"
echo "    MAC       : ${MAC_ADDRESS}"
echo "    Rootfs    : ${ROOTFS}"
echo "    /dev/dri  : ${DRI_DEVICES[*]}"
echo "    MyBook    : ${MYBOOK_MOUNT} -> /media/mybook"
echo ""

# ------------------------------------------------------------------------------
# 1. Clean up any existing container
# ------------------------------------------------------------------------------
echo "==> [1] Clean up existing container (if any)"

if virsh -c lxc:/// dominfo "${VM_NAME}" &>/dev/null; then
    STATE=$(virsh -c lxc:/// domstate "${VM_NAME}" 2>/dev/null || echo "unknown")
    if [[ "${STATE}" == "running" ]]; then
        virsh -c lxc:/// destroy "${VM_NAME}" && echo "    Stopped ${VM_NAME}" || true
    fi
    virsh -c lxc:/// undefine "${VM_NAME}" && echo "    Undefined ${VM_NAME}" || true
fi

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

# ------------------------------------------------------------------------------
# 2. Bootstrap Debian 13 rootfs
# ------------------------------------------------------------------------------
echo ""
echo "==> [2] Bootstrap Debian 13 (trixie) rootfs -- takes ~2-3 min"

debootstrap \
    --arch=amd64 \
    --include=systemd,systemd-sysv,systemd-resolved,dbus,gnupg,openssh-server,iproute2,iputils-ping,curl,ca-certificates,locales,sudo,vim,htop,netcat-openbsd,bind9-dnsutils,tcpdump \
    trixie \
    "${ROOTFS}" \
    https://deb.debian.org/debian

echo "    debootstrap complete"

# ------------------------------------------------------------------------------
# 3. Configure the rootfs
# ------------------------------------------------------------------------------
echo ""
echo "==> [3] Configure rootfs"

# Hostname
echo "${VM_NAME}" > "${ROOTFS}/etc/hostname"

# /etc/hosts
cat > "${ROOTFS}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${VM_NAME} ${VM_NAME}.chalet.lab

::1         localhost ip6-localhost ip6-loopback
EOF

# Locale
echo "en_US.UTF-8 UTF-8" > "${ROOTFS}/etc/locale.gen"
chroot "${ROOTFS}" locale-gen

# Timezone
chroot "${ROOTFS}" ln -sf /usr/share/zoneinfo/America/Montreal /etc/localtime
echo "America/Montreal" > "${ROOTFS}/etc/timezone"

# systemd-networkd for DHCP on eth0
mkdir -p "${ROOTFS}/etc/systemd/network"
cat > "${ROOTFS}/etc/systemd/network/10-eth0.network" << EOF
[Match]
Name=eth0

[Network]
DHCP=ipv4

[DHCP]
UseDNS=yes
UseDomains=yes
EOF

chroot "${ROOTFS}" systemctl enable systemd-networkd

# Static resolv.conf pointing at c-router00 on LAN10
cat > "${ROOTFS}/etc/resolv.conf" << EOF
nameserver 10.1.10.1
search chalet.lab
EOF

# Disable IPv6
cat > "${ROOTFS}/etc/sysctl.d/99-disable-ipv6.conf" << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# root password
echo "root:${ROOT_PASSWORD}" | chroot "${ROOTFS}" chpasswd

# lab user
chroot "${ROOTFS}" useradd -m -s /bin/bash -G sudo,video,render lab 2>/dev/null || true
echo "lab:${LAB_PASSWORD}" | chroot "${ROOTFS}" chpasswd

# NOPASSWD sudo for lab (no password prompt)
echo "lab ALL=(ALL) NOPASSWD:ALL" > "${ROOTFS}/etc/sudoers.d/lab"
chmod 440 "${ROOTFS}/etc/sudoers.d/lab"

# SSH authorized key for lab
mkdir -p "${ROOTFS}/home/lab/.ssh"
echo "${LAB_SSH_PUBKEY}" > "${ROOTFS}/home/lab/.ssh/authorized_keys"
chmod 700 "${ROOTFS}/home/lab/.ssh"
chmod 600 "${ROOTFS}/home/lab/.ssh/authorized_keys"
chroot "${ROOTFS}" chown -R lab:lab /home/lab/.ssh

# SSH hardening
cat > "${ROOTFS}/etc/ssh/sshd_config.d/hardening.conf" << EOF
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
AllowUsers lab
EOF

# Mount points
mkdir -p "${ROOTFS}/media/mybook"
mkdir -p "${ROOTFS}/dev/dri"

# Disable services that don't make sense in LXC
for svc in getty@tty1 serial-getty@ttyS0 systemd-udevd; do
    chroot "${ROOTFS}" systemctl disable "${svc}" 2>/dev/null || true
    chroot "${ROOTFS}" systemctl mask   "${svc}" 2>/dev/null || true
done

# MOTD
cat > "${ROOTFS}/etc/motd" << EOF
================================================================================
  JELLYFIN MEDIA SERVER - LXC CONTAINER: ${VM_NAME}
================================================================================
  Network : ${NETWORK} / ${PORTGROUP}  |  IP: ${JELLYFIN_IP}
  Media   : /media/mybook  (bind mount -> WD MyBook on host)
  GPU     : AMD Radeon 680M via VA-API (/dev/dri/renderD128)

  QUICK CHECKS:
  -------------
  Jellyfin  : systemctl status jellyfin
  VA-API    : vainfo --display drm --device /dev/dri/renderD128
  Media     : ls /media/mybook
  Logs      : journalctl -u jellyfin -f

  WEB UI    : http://${JELLYFIN_IP}:8096  (setup wizard on first access)
================================================================================
EOF

echo "    rootfs configured"

# ------------------------------------------------------------------------------
# 4. Jellyfin first-boot install service
# ------------------------------------------------------------------------------
echo ""
echo "==> [4] Jellyfin first-boot install script"

cat > "${ROOTFS}/root/install-jellyfin.sh" << 'INNEREOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> [jellyfin-install] Installing VA-API + Jellyfin..."

apt-get update -qq
apt-get install -y \
    qemu-guest-agent \
    tcpdump \
    curl \
    bind9-dnsutils \
    htop \
    iputils-ping \
    netcat-openbsd \
    vainfo \
    mesa-va-drivers \
    libva-drm2

# Add Jellyfin official repo (trixie = Debian 13)
curl -fsSL https://repo.jellyfin.org/debian/jellyfin_team.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg

echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/debian trixie main" \
    > /etc/apt/sources.list.d/jellyfin.list

apt-get update -qq
apt-get install -y jellyfin

# Add jellyfin user to video + render groups for VA-API
usermod -aG video  jellyfin
usermod -aG render jellyfin

# Pre-create /var/lib/jellyfin with correct ownership
# (the package may not create it if the home dir was missing at adduser time)
mkdir -p /var/lib/jellyfin
chown jellyfin:jellyfin /var/lib/jellyfin
chmod 750 /var/lib/jellyfin

# Pre-configure VA-API hardware transcoding
mkdir -p /etc/jellyfin
chown jellyfin:jellyfin /etc/jellyfin
cat > /etc/jellyfin/encoding.xml << 'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<EncodingOptions>
  <HardwareAccelerationType>vaapi</HardwareAccelerationType>
  <VaapiDevice>/dev/dri/renderD128</VaapiDevice>
  <EnableHardwareEncoding>true</EnableHardwareEncoding>
  <EnableToneMapping>false</EnableToneMapping>
</EncodingOptions>
XMLEOF
chown jellyfin:jellyfin /etc/jellyfin/encoding.xml

systemctl enable jellyfin
systemctl start  jellyfin

# Self-disable after successful run
rm -f /root/install-jellyfin.sh
systemctl disable jellyfin-firstboot.service 2>/dev/null || true

echo "==> [jellyfin-install] Done."
INNEREOF

chmod +x "${ROOTFS}/root/install-jellyfin.sh"

cat > "${ROOTFS}/etc/systemd/system/jellyfin-firstboot.service" << EOF
[Unit]
Description=Jellyfin first-boot install
After=network-online.target
Wants=network-online.target
ConditionPathExists=/root/install-jellyfin.sh

[Service]
Type=oneshot
ExecStart=/root/install-jellyfin.sh
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chroot "${ROOTFS}" systemctl enable jellyfin-firstboot.service
echo "    first-boot service enabled"

# ------------------------------------------------------------------------------
# 5. Build libvirt LXC domain XML
# ------------------------------------------------------------------------------
echo ""
echo "==> [5] Build libvirt LXC domain XML"

DRI_HOSTDEV_XML=""
for dev in "${DRI_DEVICES[@]}"; do
    DEVNAME=$(basename "${dev}")
    DRI_HOSTDEV_XML="${DRI_HOSTDEV_XML}
    <hostdev mode='capabilities' type='misc'>
      <source>
        <char>${dev}</char>
      </source>
      <alias name='${DEVNAME}'/>
    </hostdev>"
done

DOMAIN_XML="/tmp/${VM_NAME}-domain.xml"
cat > "${DOMAIN_XML}" << EOF
<domain type='lxc'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>2048</memory>
  <currentMemory unit='MiB'>2048</currentMemory>
  <vcpu>4</vcpu>

  <os>
    <type>exe</type>
    <init>/sbin/init</init>
  </os>

  <features>
    <privnet/>
  </features>

  <clock offset='utc'/>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>

  <devices>
    <emulator>/usr/lib/libvirt/libvirt_lxc</emulator>

    <!-- Root filesystem -->
    <filesystem type='mount' accessmode='passthrough'>
      <source dir='${ROOTFS}'/>
      <target dir='/'/>
    </filesystem>

    <!-- WD MyBook bind mount -->
    <filesystem type='mount' accessmode='passthrough'>
      <source dir='${MYBOOK_MOUNT}'/>
      <target dir='/media/mybook'/>
    </filesystem>

    <!-- Network: LAN10 via lan-ext10 bridge (br-ext10) -->
    <interface type='network'>
      <mac address='${MAC_ADDRESS}'/>
      <source network='${NETWORK}' portgroup='${PORTGROUP}'/>
      <target dev='veth-jellyfin'/>
      <model type='virtio'/>
      <alias name='net0'/>
    </interface>

    <!-- Console -->
    <console type='pty'>
      <target type='lxc' port='0'/>
    </console>

    <!-- /dev/dri passthrough for VA-API via LXC hostdev misc -->
${DRI_HOSTDEV_XML}

  </devices>
</domain>
EOF

echo "    Domain XML written: ${DOMAIN_XML}"

# ------------------------------------------------------------------------------
# 6. Define and start the container
# ------------------------------------------------------------------------------
echo ""
echo "==> [6] Define and start LXC container"

virsh -c lxc:/// define "${DOMAIN_XML}"
virsh -c lxc:/// start    "${VM_NAME}"
virsh -c lxc:/// autostart "${VM_NAME}"

echo "    Started and autostart enabled"

# ------------------------------------------------------------------------------
# 7. Wait for Jellyfin to become healthy
# ------------------------------------------------------------------------------
echo ""
echo "==> [7] Waiting for Jellyfin to become healthy"
echo "    (first boot installs packages -- may take 3-5 min)"
echo ""

MAX_WAIT=360   # 6 minutes total
INTERVAL=5     # check every 5 seconds
ELAPSED=0
DOTS=0

printf "    "

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    if curl -sf "http://${JELLYFIN_IP}:8096/health" &>/dev/null; then
        echo ""
        echo ""
        echo "    Jellyfin is UP after ${ELAPSED}s"
        JELLYFIN_UP=true
        break
    fi

    # Print a dot every interval to show progress
    printf "."
    DOTS=$((DOTS + 1))

    # Newline every 60 dots for readability
    if (( DOTS % 60 == 0 )); then
        printf "\n    "
    fi

    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ "${JELLYFIN_UP:-false}" != "true" ]]; then
    echo ""
    echo ""
    echo "    WARN: Jellyfin not responding after ${MAX_WAIT}s"
    echo "    Check install progress:"
    echo "      virsh -c lxc:/// console ${VM_NAME}   (Ctrl-] to exit)"
    echo "      -- then inside container:"
    echo "      journalctl -u jellyfin-firstboot -f"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  [15-create-jellyfin-lxc] Complete"
echo ""
echo "  Container : ${VM_NAME}  (LXC via libvirt)"
echo "  Network   : ${NETWORK} / ${PORTGROUP}"
echo "  MAC       : ${MAC_ADDRESS}"
echo "  IP        : ${JELLYFIN_IP}"
echo "  Memory    : 2048 MB / 4 vCPU"
echo "  Rootfs    : ${ROOTFS}"
echo "  MyBook    : ${MYBOOK_MOUNT} -> /media/mybook"
echo "  /dev/dri  : ${DRI_DEVICES[*]}"
echo ""
echo "  Useful commands:"
echo "    virsh -c lxc:/// list --all"
echo "    virsh -c lxc:/// console  ${VM_NAME}   (Ctrl-] to exit)"
echo "    virsh -c lxc:/// shutdown ${VM_NAME}"
echo "    virsh -c lxc:/// start    ${VM_NAME}"
echo "    ssh lab@${JELLYFIN_IP}"
echo ""
echo "  VA-API check:"
echo "    vainfo --display drm --device /dev/dri/renderD128"
echo ""
echo "  Jellyfin web UI: http://${JELLYFIN_IP}:8096"
echo ""
echo "  SSH tunnel (add to ~/.ssh/config):"
echo "    Host jellyfin-tunnel"
echo "      HostName c-server00"
echo "      User lab"
echo "      LocalForward 8096 ${JELLYFIN_IP}:8096"
echo "    Then: ssh -N jellyfin-tunnel"
echo "================================================================"
