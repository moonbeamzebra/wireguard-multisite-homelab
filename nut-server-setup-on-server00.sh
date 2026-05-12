#!/bin/bash
# nut-server-setup-on-server00.sh
# Install and configure NUT as a standalone server directly on server00 (Debian 13)
#
# The UPS (CyberPower EC850LCD) is connected via USB directly to server00.
# server00 runs the NUT driver, server, and monitor all-in-one.
# On LOWBATT, NUT gracefully stops all KVMs and LXC containers then powers off.
# server00 restarts automatically when power returns via BIOS "Power On after AC Loss".
# No Pi, no WOL needed.
#
# USB ID: 0764:0501 (CyberPower EC850LCD)
#
# Usage:
#   source site-X.env && source site-X-secrets.env
#   sudo -E bash nut-server-setup-on-server00.sh
#
# Required env vars (from site-X.env):
#   SITE_NAME  SITE_LETTER  PRIMARY_DOMAIN
#   NUT_UPS_NAME  NUT_USER
#   NUT_BATTERY_WARN   (percentage 1-99, or -1 to use firmware default)
#
# Required env vars (from site-X-secrets.env):
#   NUT_PASSWORD

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root: sudo -E bash $0"
    exit 1
fi

for VAR in SITE_NAME SITE_LETTER PRIMARY_DOMAIN \
           NUT_UPS_NAME NUT_USER NUT_PASSWORD NUT_BATTERY_WARN; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "       Run: source site-X.env && source site-X-secrets.env && sudo -E bash $0"
        exit 1
    fi
done

# Validate NUT_BATTERY_WARN
if [[ "${NUT_BATTERY_WARN}" != "-1" ]] && \
   ! [[ "${NUT_BATTERY_WARN}" =~ ^[0-9]+$ ]] || \
   { [[ "${NUT_BATTERY_WARN}" =~ ^[0-9]+$ ]] && \
     [[ "${NUT_BATTERY_WARN}" -lt 1 || "${NUT_BATTERY_WARN}" -gt 99 ]]; }; then
    echo "ERROR: NUT_BATTERY_WARN must be -1 (firmware default) or 1-99 (percent)"
    exit 1
fi

FINALDELAY=120
UPS_USB_VENDOR="0764"
UPS_USB_PRODUCT="0501"

echo "=== [nut-server-setup-on-server00] Start ==="
echo "    Site          : ${SITE_NAME} (${SITE_LETTER})"
echo "    UPS           : ${NUT_UPS_NAME} (CyberPower EC850LCD)"
if [[ "${NUT_BATTERY_WARN}" == "-1" ]]; then
    echo "    Shutdown at   : firmware default (NUT_BATTERY_WARN=-1)"
else
    echo "    Shutdown at   : ${NUT_BATTERY_WARN}% battery"
fi
echo "    Final delay   : ${FINALDELAY}s"
echo "    Auto-restart  : via BIOS 'Power On after AC Loss' (no WOL needed)"
echo ""

# ------------------------------------------------------------------------------
# 1. Install NUT
# ------------------------------------------------------------------------------
echo "==> [1/6] Install NUT"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y nut nut-client

if lsusb | grep -q "${UPS_USB_VENDOR}:${UPS_USB_PRODUCT}"; then
    echo "    USB UPS detected: $(lsusb | grep ${UPS_USB_VENDOR}:${UPS_USB_PRODUCT})"
else
    echo "    WARN: USB device ${UPS_USB_VENDOR}:${UPS_USB_PRODUCT} not found"
    echo "          Is the UPS USB cable connected to server00?"
fi

# ------------------------------------------------------------------------------
# 2. Configure NUT
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/6] Configure NUT"

mkdir -p /etc/nut

# ups.conf -- UPS driver configuration
# When NUT_BATTERY_WARN=-1: use firmware LOWBATT signal as-is (no ignorelb)
# When NUT_BATTERY_WARN=N:  use software threshold via ignorelb + override/default
if [[ "${NUT_BATTERY_WARN}" == "-1" ]]; then
    cat > /etc/nut/ups.conf << EOF
# CyberPower EC850LCD -- USB ID ${UPS_USB_VENDOR}:${UPS_USB_PRODUCT}
[${NUT_UPS_NAME}]
    driver = usbhid-ups
    port   = auto
    desc   = "CyberPower EC850LCD"
    # Using firmware LOWBATT signal (NUT_BATTERY_WARN=-1)
    # Shutdown threshold controlled by UPS firmware
EOF
    echo "    ups.conf    : firmware LOWBATT (no software threshold)"
else
    cat > /etc/nut/ups.conf << EOF
# CyberPower EC850LCD -- USB ID ${UPS_USB_VENDOR}:${UPS_USB_PRODUCT}
[${NUT_UPS_NAME}]
    driver = usbhid-ups
    port   = auto
    desc   = "CyberPower EC850LCD"
    # ignorelb: use software threshold instead of firmware LOWBATT signal.
    # Without ignorelb, CyberPower firmware ignores override.battery.charge.low.
    ignorelb
    # Both directives needed -- override sets the DB value, default is the fallback.
    # IMPORTANT: requires restarting nut-driver@${NUT_UPS_NAME} (not just nut-server)
    override.battery.charge.low = ${NUT_BATTERY_WARN}
    default.battery.charge.low  = ${NUT_BATTERY_WARN}
EOF
    echo "    ups.conf    : ignorelb + software threshold at ${NUT_BATTERY_WARN}%"
fi

cat > /etc/nut/nut.conf << EOF
# standalone: driver, server, and monitor all on this machine
MODE=standalone
EOF

cat > /etc/nut/upsd.conf << EOF
LISTEN 127.0.0.1 3493
MAXAGE 15
EOF

cat > /etc/nut/upsd.users << EOF
[${NUT_USER}]
    password = ${NUT_PASSWORD}
    upsmon master
EOF

cat > /etc/nut/upsmon.conf << EOF
# Monitor local UPS -- standalone master
MONITOR ${NUT_UPS_NAME}@localhost 1 ${NUT_USER} ${NUT_PASSWORD} master

POLLFREQ 5
POLLFREQALERT 2
FINALDELAY ${FINALDELAY}

POWERDOWNFLAG /etc/nut/killpower

# Gracefully stop all KVMs + LXC then poweroff
SHUTDOWNCMD "/usr/local/sbin/nut-shutdown.sh"

NOTIFYFLAG ONLINE  SYSLOG+WALL
NOTIFYFLAG ONBATT  SYSLOG+WALL
NOTIFYFLAG LOWBATT SYSLOG+WALL
NOTIFYFLAG FSD     SYSLOG+WALL
EOF

chown -R root:nut /etc/nut/
chmod 640 /etc/nut/ups.conf /etc/nut/upsd.conf \
          /etc/nut/upsd.users /etc/nut/upsmon.conf

echo "    nut.conf    : MODE=standalone"
echo "    upsd.conf   : LISTEN 127.0.0.1 (local only)"
echo "    upsd.users  : ${NUT_USER} master"
echo "    upsmon.conf : FINALDELAY ${FINALDELAY}s"

# ------------------------------------------------------------------------------
# 3. Graceful shutdown script (parallel KVM + LXC shutdown)
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/6] /usr/local/sbin/nut-shutdown.sh"

cat > /usr/local/sbin/nut-shutdown.sh << SHUTEOF
#!/bin/bash
# NUT SHUTDOWNCMD -- runs as root (upsmon runs as root on Debian)
#
# Sends shutdown signals to ALL KVMs and ALL LXC in parallel,
# then waits for each group separately.
#
# Sequence:
#   1. Send virsh shutdown to all KVMs simultaneously
#   2. Send virsh shutdown to all LXC simultaneously
#   3. Wait up to 60s for KVMs, force-destroy stragglers
#   4. Wait up to 30s for LXC, force-destroy stragglers
#   5. Log remaining battery charge (for tuning the threshold)
#   6. systemctl poweroff

set -euo pipefail

LOGFILE="/var/log/nut-shutdown.log"
KVM_TIMEOUT=60
LXC_TIMEOUT=30
NUT_UPS="${NUT_UPS_NAME}@localhost"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1" | tee -a "\${LOGFILE}"
}

log "=== NUT shutdown triggered ==="

KVM_DOMAINS=\$(virsh list --name --state-running 2>/dev/null || true)
LXC_DOMAINS=\$(virsh -c lxc:/// list --name --state-running 2>/dev/null || true)

log "Running KVMs : \$(echo \${KVM_DOMAINS} | tr '\n' ' ')"
log "Running LXCs : \$(echo \${LXC_DOMAINS} | tr '\n' ' ')"

# Send all shutdown signals in parallel
for DOM in \${KVM_DOMAINS}; do
    log "Shutdown KVM (parallel): \${DOM}"
    virsh shutdown "\${DOM}" 2>/dev/null || log "WARN: shutdown \${DOM} failed"
done

for DOM in \${LXC_DOMAINS}; do
    log "Shutdown LXC (parallel): \${DOM}"
    virsh -c lxc:/// shutdown "\${DOM}" 2>/dev/null || log "WARN: shutdown \${DOM} failed"
done

[[ -n "\${KVM_DOMAINS}\${LXC_DOMAINS}" ]] && \
    log "All shutdown signals sent -- waiting for KVMs (\${KVM_TIMEOUT}s) then LXC (\${LXC_TIMEOUT}s)"

# Wait for KVMs
if [[ -n "\${KVM_DOMAINS}" ]]; then
    ELAPSED=0
    while [[ \${ELAPSED} -lt \${KVM_TIMEOUT} ]]; do
        RUNNING=\$(virsh list --name --state-running 2>/dev/null || true)
        [[ -z "\${RUNNING}" ]] && break
        sleep 2; ELAPSED=\$((ELAPSED + 2))
        log "Waiting KVMs (\${ELAPSED}s): \${RUNNING}"
    done
    for DOM in \$(virsh list --name --state-running 2>/dev/null || true); do
        log "Force-destroying KVM: \${DOM}"
        virsh destroy "\${DOM}" 2>/dev/null || true
    done
fi
log "KVMs: done"

# Wait for LXC
if [[ -n "\${LXC_DOMAINS}" ]]; then
    ELAPSED=0
    while [[ \${ELAPSED} -lt \${LXC_TIMEOUT} ]]; do
        RUNNING=\$(virsh -c lxc:/// list --name --state-running 2>/dev/null || true)
        [[ -z "\${RUNNING}" ]] && break
        sleep 2; ELAPSED=\$((ELAPSED + 2))
        log "Waiting LXC (\${ELAPSED}s): \${RUNNING}"
    done
    for DOM in \$(virsh -c lxc:/// list --name --state-running 2>/dev/null || true); do
        log "Force-destroying LXC: \${DOM}"
        virsh -c lxc:/// destroy "\${DOM}" 2>/dev/null || true
    done
fi
log "LXCs: done"

# Log remaining battery charge -- useful for tuning the shutdown threshold
BATT_CHARGE=\$(upsc "\${NUT_UPS}" battery.charge 2>/dev/null || echo "unknown")
BATT_RUNTIME=\$(upsc "\${NUT_UPS}" battery.runtime 2>/dev/null || echo "unknown")
UPS_STATUS=\$(upsc "\${NUT_UPS}" ups.status 2>/dev/null || echo "unknown")
log "=== Battery at poweroff: charge=\${BATT_CHARGE}%  runtime=\${BATT_RUNTIME}s  status=\${UPS_STATUS} ==="
log "=== All workloads stopped -- powering off ==="

sync
systemctl poweroff
SHUTEOF

chmod 755 /usr/local/sbin/nut-shutdown.sh
touch /var/log/nut-shutdown.log

echo "    /usr/local/sbin/nut-shutdown.sh: written"
echo "    Battery charge logged at poweroff (for threshold tuning)"

# ------------------------------------------------------------------------------
# 4. udev rule for USB permissions
# ------------------------------------------------------------------------------
echo ""
echo "==> [4/6] udev rule for CyberPower USB"

if ls /lib/udev/rules.d/*nut* 2>/dev/null | grep -q .; then
    echo "    NUT udev rules already installed by package:"
    ls /lib/udev/rules.d/*nut*
else
    cat > /etc/udev/rules.d/99-nut-cyberpower.rules << EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="${UPS_USB_VENDOR}", ATTR{idProduct}=="${UPS_USB_PRODUCT}", GROUP="nut", MODE="0660"
EOF
    echo "    custom udev rule written: /etc/udev/rules.d/99-nut-cyberpower.rules"
fi

udevadm control --reload-rules
udevadm trigger --subsystem-match=usb
udevadm settle
echo "    udev rules reloaded"

# ------------------------------------------------------------------------------
# 5. Enable and start NUT services
# ------------------------------------------------------------------------------
echo ""
echo "==> [5/6] Enable and start NUT services"

systemctl enable nut-driver@${NUT_UPS_NAME} nut-server nut-monitor

# Restart order matters:
# 1. driver -- reads ups.conf, applies override/default battery.charge.low
# 2. server -- upsd, connects to driver socket
# 3. monitor -- upsmon, connects to upsd
systemctl restart nut-driver@${NUT_UPS_NAME}
sleep 3
systemctl restart nut-server
sleep 2
systemctl restart nut-monitor

sleep 3

if upsc "${NUT_UPS_NAME}@localhost" battery.charge &>/dev/null; then
    CHARGE=$(upsc "${NUT_UPS_NAME}@localhost" battery.charge 2>/dev/null)
    STATUS=$(upsc "${NUT_UPS_NAME}@localhost" ups.status 2>/dev/null)
    CHARGE_LOW=$(upsc "${NUT_UPS_NAME}@localhost" battery.charge.low 2>/dev/null)
    echo "    UPS status       : ${STATUS}"
    echo "    Battery          : ${CHARGE}%"
    echo "    Shutdown at      : ${CHARGE_LOW}%"
    if [[ "${NUT_BATTERY_WARN}" != "-1" ]] && [[ "${CHARGE_LOW}" != "${NUT_BATTERY_WARN}" ]]; then
        echo "    WARN: battery.charge.low=${CHARGE_LOW}% but expected ${NUT_BATTERY_WARN}%"
        echo "          Check: sudo systemctl restart nut-driver@${NUT_UPS_NAME}"
    fi
else
    echo "    WARN: upsc query failed -- check: journalctl -u nut-server -n 20"
fi

# ------------------------------------------------------------------------------
# 6. BIOS reminder
# ------------------------------------------------------------------------------
echo ""
echo "==> [6/6] BIOS reminder"
echo ""
echo "    IMPORTANT: Verify BIOS setting on ${SITE_LETTER}-server00:"
echo "    'Restore on AC Power Loss' must be set to POWER ON"
echo "    This replaces WOL -- server00 starts automatically when power returns."

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  [nut-server-setup-on-server00] Complete"
echo ""
echo "  UPS       : ${NUT_UPS_NAME} (CyberPower EC850LCD, standalone)"
if [[ "${NUT_BATTERY_WARN}" == "-1" ]]; then
    echo "  Shutdown  : firmware LOWBATT signal"
else
    echo "  Shutdown  : at ${NUT_BATTERY_WARN}% battery (ignorelb + override)"
fi
echo "  Delay     : ${FINALDELAY}s final delay"
echo "  Restart   : BIOS auto power-on"
echo ""
echo "  Useful commands:"
echo "    upsc ${NUT_UPS_NAME}@localhost"
echo "    upsc ${NUT_UPS_NAME}@localhost battery.charge"
echo "    upsc ${NUT_UPS_NAME}@localhost battery.charge.low"
echo "    upsc ${NUT_UPS_NAME}@localhost ups.status"
echo "    journalctl -u nut-monitor -f"
echo "    cat /var/log/nut-shutdown.log"
echo ""
echo "  To test:"
echo "    sudo vi /etc/nut/ups.conf"
echo "    # Set both override and default to 98 for quick test"
echo "    sudo systemctl restart nut-driver@${NUT_UPS_NAME}"
echo "    sleep 3 && sudo systemctl restart nut-server nut-monitor"
echo "    upsc ${NUT_UPS_NAME}@localhost battery.charge.low  # must show 98"
echo "    # Unplug UPS, watch: journalctl -u nut-monitor -f"
echo "    # Check after: cat /var/log/nut-shutdown.log"
echo "    # (shows battery % at moment of poweroff -- use to tune threshold)"
echo "================================================================"
