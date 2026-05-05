#!/bin/bash
# 12-host-hardening.sh -- SSH and firewall hardening for the KVM host
#
# Two modes -- must be specified explicitly:
#
#   dev   Both machines at the same site during development.
#         - SSH listens on all interfaces
#         - iptables allows SSH from WiFi (WIFI_SUBNET) and LAN10
#         - WiFi interface config left in place
#
#   prod  Machines deployed at their final sites with Google Nest on LAN10.
#         - SSH listens on LAN10 IP only
#         - iptables allows SSH from LAN10 and remote LAN10 only
#         - WiFi interface config moved to /root/ (disabled)
#
# Usage:
#   source site-A.env && sudo -E bash 12-host-hardening.sh dev
#   source site-A.env && sudo -E bash 12-host-hardening.sh prod
#
# Required env vars (from site-*.env):
#   IP_BR_EXT            host IP on LAN10 bridge  e.g. 10.0.10.2/24
#   LAN10_SUBNET         e.g. 10.0.10.0/24
#   REMOTE_LAN10_SUBNET  e.g. 10.1.10.0/24
#   PRESEED_IF_LAN       WiFi interface name (for ifup/ifdown)
#   WIFI_SUBNET          e.g. 192.168.86.0/24  (dev mode only)
#
# Design:
#   - iptables direct -- consistent with bastion and router00, no UFW
#   - FORWARD ACCEPT on host: VM bridge traffic must not be filtered here;
#     each VM enforces its own rules
#   - AllowTcpForwarding yes: required for SSH ProxyJump through this host
#   - Idempotent: safe to re-run in either mode

set -euo pipefail

MODE="${1:-}"
if [[ "${MODE}" != "dev" && "${MODE}" != "prod" ]]; then
    echo "ERROR: mode required"
    echo ""
    echo "  dev   -- WiFi access kept (machines still at same site)"
    echo "  prod  -- WiFi closed (Nest in place, machines at final sites)"
    echo ""
    echo "Usage: source site-A.env && sudo -E bash $0 dev|prod"
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root: sudo -E bash $0 ${MODE}"
    exit 1
fi

for VAR in IP_BR_EXT LAN10_SUBNET REMOTE_LAN10_SUBNET PRESEED_IF_LAN; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "       Run: source site-A.env && sudo -E bash $0 ${MODE}"
        exit 1
    fi
done

if [[ "${MODE}" == "dev" && -z "${WIFI_SUBNET:-}" ]]; then
    echo "ERROR: WIFI_SUBNET not set -- required for dev mode"
    echo "       Add: export WIFI_SUBNET=192.168.86.0/24  to your site-*.env"
    exit 1
fi

HOST_IP="${IP_BR_EXT%%/*}"

echo "==> Host hardening [${MODE}] -- ${HOST_IP} (${LAN10_SUBNET})"

# -- Packages ------------------------------------------------------------------
echo "==> Installing packages"
apt-get update -qq
echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    fail2ban iptables iptables-persistent

if command -v ufw &>/dev/null; then
    echo "==> Removing UFW (replaced by iptables direct)"
    ufw --force disable
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq ufw 2>/dev/null || true
fi

# -- SSH hardening -------------------------------------------------------------
echo "==> Hardening SSH (mode: ${MODE})"

if [[ "${MODE}" == "dev" ]]; then
    LISTEN_LINE=""
else
    LISTEN_LINE="ListenAddress ${HOST_IP}"
fi

cat > /etc/ssh/sshd_config.d/hardening.conf << EOF
# Managed by 12-host-hardening.sh (mode: ${MODE}) -- do not edit manually

${LISTEN_LINE}

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no

# Required for ProxyJump: Mac -> server00 -> bastion / VMs
AllowTcpForwarding yes
AllowUsers lab
EOF

systemctl restart ssh

if [[ "${MODE}" == "dev" ]]; then
    echo "    SSH listening on all interfaces (dev mode)"
else
    echo "    SSH listening on ${HOST_IP}:22 only (prod mode)"
fi

# -- WiFi interface ------------------------------------------------------------
if [[ "${MODE}" == "prod" ]]; then
    if [[ -f /etc/network/interfaces.d/01-wifi.conf ]]; then
        mv /etc/network/interfaces.d/01-wifi.conf /root/01-wifi.conf.disabled
        ip link set "${PRESEED_IF_LAN}" down 2>/dev/null || true
        echo "==> WiFi config moved to /root/01-wifi.conf.disabled, interface down"
    else
        echo "==> WiFi config already removed"
    fi
else
    if [[ -f /root/01-wifi.conf.disabled && ! -f /etc/network/interfaces.d/01-wifi.conf ]]; then
        cp /root/01-wifi.conf.disabled /etc/network/interfaces.d/01-wifi.conf
        echo "==> WiFi config restored from /root/01-wifi.conf.disabled"
    else
        echo "==> WiFi interface: left in place (dev mode)"
    fi
    if [[ -f /etc/network/interfaces.d/01-wifi.conf ]]; then
        ifup "${PRESEED_IF_LAN}" 2>/dev/null || true
    fi
fi

# -- iptables ------------------------------------------------------------------
#
# INPUT DROP by default -- host protects itself only.
# FORWARD ACCEPT -- required for KVM bridge traffic; each VM enforces its own rules.
# OUTPUT ACCEPT.
#
echo "==> Configuring iptables (mode: ${MODE})"

iptables -F
iptables -X
iptables -t nat    -F
iptables -t mangle -F

iptables -P INPUT   DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH and ICMP from LAN10 (infrastructure subnet) -- both modes
iptables -A INPUT -i br-ext10 -s "${LAN10_SUBNET}"        -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -i br-ext10 -s "${REMOTE_LAN10_SUBNET}" -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -i br-ext10 -s "${LAN10_SUBNET}"        -p icmp           -j ACCEPT
iptables -A INPUT -i br-ext10 -s "${REMOTE_LAN10_SUBNET}" -p icmp           -j ACCEPT

if [[ "${MODE}" == "dev" ]]; then
    # WiFi access during development -- removed when switching to prod
    iptables -A INPUT -s "${WIFI_SUBNET}" -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s "${WIFI_SUBNET}" -p icmp           -j ACCEPT
    echo "    WiFi SSH allowed from ${WIFI_SUBNET} (dev mode)"
fi

netfilter-persistent save

echo ""
iptables -L INPUT -n -v --line-numbers

# -- Fail2ban ------------------------------------------------------------------
echo "==> Configuring fail2ban"

cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled  = true
port     = ssh
maxretry = 3
bantime  = 1h
findtime = 10m
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban

# -- Summary -------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Host hardening complete [mode: ${MODE}]"
echo ""
if [[ "${MODE}" == "dev" ]]; then
echo "  SSH        : listening on all interfaces"
echo "  SSH access : ${LAN10_SUBNET}  ${REMOTE_LAN10_SUBNET}  ${WIFI_SUBNET}"
echo ""
echo "  When Nest is in place at final site, switch to prod:"
echo "    source site-A.env && sudo -E bash 12-host-hardening.sh prod"
else
echo "  SSH        : listening on ${HOST_IP}:22 only"
echo "  SSH access : ${LAN10_SUBNET}  ${REMOTE_LAN10_SUBNET}"
echo "  WiFi       : disabled (/root/01-wifi.conf.disabled)"
fi
echo ""
echo "  fail2ban   : active"
echo "  iptables   : active and persistent"
echo "================================================================"
