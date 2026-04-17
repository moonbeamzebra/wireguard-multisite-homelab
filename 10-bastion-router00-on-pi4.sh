#!/bin/ash
# ==============================================================================
# 10-bastion-router00-on-pi4.sh
#
# Full automated setup of bastion + router00 on a Raspberry Pi 4 running Alpine.
# Run as root after a fresh Alpine install (see pi4-bootstrap.md for the
# Alpine install procedure).
#
# Prerequisites -- all files must be present in the same directory as this
# script before you run it:
#
#   site-B-pi4-atCottage.env          (or rename from site-B-pi4-simulationAtHome.env)
#   secrets-B-pi4.env                 (gitignored -- fill from template)
#   secrets-pi4-wg0-core.conf         (gitignored -- fill from template)
#
# Usage:
#   su -           # become root (or run directly as root)
#   cd /path/to/scripts
#   ash 10-bastion-router00-on-pi4.sh
#
# The script is idempotent: safe to re-run after a failed attempt.
# A full reboot is triggered at the end.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root"
    exit 1
fi

for f in site-B-pi4-atCottage.env secrets-B-pi4.env secrets-pi4-wg0-core.conf; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        echo "ERROR: required file not found: ${SCRIPT_DIR}/${f}"
        echo "       Copy and fill in the corresponding .template file, then re-run."
        exit 1
    fi
done

echo "==> All required files present. Starting setup."

# ------------------------------------------------------------------------------
# 1. Directories
# ------------------------------------------------------------------------------

echo "==> Creating directories"
mkdir -p /root/lab /etc/wireguard /etc/local.d /etc/ssh/config_custom /var/run/sshd

# ------------------------------------------------------------------------------
# 2. Packages
# ------------------------------------------------------------------------------

echo "==> Installing packages"
sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories
apk update
apk add wireguard-tools iproute2 dnsmasq iptables tcpdump htop sudo
sed -i 's/\(.*\/community\)/#\1/' /etc/apk/repositories
rm -rf /var/cache/apk/*

# ------------------------------------------------------------------------------
# 3. Copy env and config files to /root/lab
# ------------------------------------------------------------------------------

echo "==> Copying env and config files to /root/lab"
cp "${SCRIPT_DIR}/site-B-pi4-atCottage.env"   /root/lab/site-B-pi4.env
cp "${SCRIPT_DIR}/secrets-B-pi4.env"           /root/lab/secrets-B-pi4.env
cp "${SCRIPT_DIR}/secrets-pi4-wg0-core.conf"   /etc/wireguard/wg0-core.conf
chmod 600 /root/lab/secrets-B-pi4.env
chmod 600 /etc/wireguard/wg0-core.conf

if [ -f "${SCRIPT_DIR}/site-B-pi4-simulationAtHome.env" ]; then
    cp "${SCRIPT_DIR}/site-B-pi4-simulationAtHome.env" /root/lab/
fi

# ------------------------------------------------------------------------------
# 4. /etc/local.d/network.start
#    Brings up both network namespaces, WireGuard, dnsmasq, and all iptables
#    rules at boot via the OpenRC 'local' service.
# ------------------------------------------------------------------------------

echo "==> Writing /etc/local.d/network.start"
cat > /etc/local.d/network.start << 'NETSTART'
#!/bin/ash

# --- 0. Environment ---
. /root/lab/site-B-pi4.env
. /root/lab/secrets-B-pi4.env
modprobe wireguard
modprobe tun

# --- 1. Cleanup existing namespaces (idempotent restart) ---
ip netns del bastion  2>/dev/null || true
ip netns del router00 2>/dev/null || true

# --- 2. Namespaces and VETH pair (DMZ link between bastion and router00) ---
ip netns add bastion
ip netns add router00
ip link add v-bastion type veth peer name v-router00
ip link set v-bastion  netns bastion
ip link set v-router00 netns router00

ip netns exec bastion  hostname ${BASTION_HOSTNAME}
ip netns exec router00 hostname ${ROUTER00_HOSTNAME}

# --- 3. Bastion: WAN (USB dongle eth1) + DMZ veth ---
ip link set ${IF_WAN} netns bastion
ip netns exec bastion ip addr add ${BASTION_IP_eth0}/${BASTION_MASK_eth0} dev ${IF_WAN}
ip netns exec bastion ip link set ${IF_WAN} up
ip netns exec bastion ip route add default via ${BASTION_GW_eth0}

ip netns exec bastion ip addr add ${BASTION_IP_eth1}/30 dev v-bastion
ip netns exec bastion ip link set v-bastion up
ip netns exec bastion ip link set lo up
ip netns exec bastion ip route add 10.1.1.0/30 dev v-bastion scope link

# --- 4. Router00: LAN (integrated RJ45 eth0) + DMZ veth ---
ip link set ${IF_LAN} netns router00
ip netns exec router00 ip addr add ${ROUTER00_IP_eth1}/24 dev ${IF_LAN}
ip netns exec router00 ip link set ${IF_LAN} up

ip netns exec router00 ip addr add ${ROUTER00_IP_eth0}/30 dev v-router00
ip netns exec router00 ip link set v-router00 up
ip netns exec router00 ip link set lo up
ip netns exec router00 ip route add default via ${ROUTER00_GW_eth0}
ip netns exec router00 ip route add 10.1.1.0/30 dev v-router00 scope link

# --- 5. IP forwarding ---
ip netns exec bastion  sysctl -w net.ipv4.ip_forward=1
ip netns exec router00 sysctl -w net.ipv4.ip_forward=1

# --- 6. WireGuard (manual -- wg-quick does not work inside a netns) ---
ip netns exec bastion ip link add dev wg0 type wireguard
ip netns exec bastion wg setconf wg0 /etc/wireguard/wg0-core.conf
ip netns exec bastion ip addr add ${WG_ADDR} dev wg0
ip netns exec bastion ip link set wg0 up

# Routes: remote site A via tunnel, local site B LANs via router00 DMZ
ip netns exec bastion ip route add 10.0.0.0/16 dev wg0
ip netns exec bastion ip route add 10.1.0.0/16 via ${ROUTER00_IP_eth0}

# --- 7. dnsmasq (in router00 namespace) ---
ip netns exec router00 dnsmasq --conf-file=/etc/dnsmasq-cottage.conf

# --- 8. iptables -- bastion ---
ip netns exec bastion iptables -F
ip netns exec bastion iptables -t nat    -F
ip netns exec bastion iptables -t mangle -F
ip netns exec bastion iptables -P INPUT   DROP
ip netns exec bastion iptables -P FORWARD DROP

# NAT: WAN outbound
ip netns exec bastion iptables -t nat -A POSTROUTING -o ${IF_WAN} -j MASQUERADE

# INPUT
ip netns exec bastion iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec bastion iptables -A INPUT -i lo              -j ACCEPT
ip netns exec bastion iptables -A INPUT -i ${IF_WAN}   -p udp --dport 51820 -j ACCEPT
ip netns exec bastion iptables -A INPUT -i v-bastion   -p icmp               -j ACCEPT
ip netns exec bastion iptables -A INPUT -i v-bastion   -p tcp --dport 22     -j ACCEPT

# FORWARD: tunnel <-> DMZ <-> WAN
ip netns exec bastion iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec bastion iptables -A FORWARD -i wg0       -o v-bastion  -j ACCEPT
ip netns exec bastion iptables -A FORWARD -i v-bastion -o wg0        -j ACCEPT
ip netns exec bastion iptables -A FORWARD -i v-bastion -o ${IF_WAN}  -j ACCEPT

# Clamp TCP MSS to PMTU (prevents stalls over the WireGuard tunnel)
ip netns exec bastion iptables -t mangle -A FORWARD \
    -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# --- 9. iptables -- router00 ---
ip netns exec router00 iptables -F
ip netns exec router00 iptables -P INPUT   DROP
ip netns exec router00 iptables -P FORWARD DROP

# INPUT
ip netns exec router00 iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec router00 iptables -A INPUT -i lo               -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p udp --dport 67:68 -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p udp --dport 53    -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p tcp --dport 53    -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p tcp --dport 22    -j ACCEPT
ip netns exec router00 iptables -A INPUT -i v-router00       -j ACCEPT

# FORWARD: LAN <-> DMZ
ip netns exec router00 iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec router00 iptables -A FORWARD -i ${IF_LAN}    -o v-router00 -j ACCEPT
ip netns exec router00 iptables -A FORWARD -i v-router00   -o ${IF_LAN}  -j ACCEPT

# --- 10. Disable Alpine native sshd (SSH handled by mgmt-access.sh below) ---
rc-update del sshd default 2>/dev/null || true

# --- 11. Management access ---
# Comment out this line to restrict access to console only
/root/lab/mgmt-access.sh

NETSTART
chmod +x /etc/local.d/network.start
rc-update add local default

# ------------------------------------------------------------------------------
# 5. /root/lab/mgmt-access.sh
#    Sets up two SSHD instances:
#      - entry SSHD in router00 ns  (10.1.10.1:22) -- ProxyJump only, no shell
#      - host  SSHD in default ns   (fmp-d IP:22)  -- shell, emergency access
#    The fmp veth pair (fmp-d / fmp-u) bridges default ns and router00 ns for
#    management traffic only.
# ------------------------------------------------------------------------------

echo "==> Writing /root/lab/mgmt-access.sh"
cat > /root/lab/mgmt-access.sh << 'MGMT'
#!/bin/ash

if [ -f /root/lab/secrets-B-pi4.env ]; then
    . /root/lab/secrets-B-pi4.env
fi

# Generate host keys if missing
ssh-keygen -A

# Passwordless sudo for 'lab'
echo "lab ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/lab
chmod 0440 /etc/sudoers.d/lab

# authorized_keys for 'lab'
if [ -n "$LAB_SSH_PUBKEY" ]; then
    mkdir -p /home/lab/.ssh
    echo "$LAB_SSH_PUBKEY" > /home/lab/.ssh/authorized_keys
    chown -R lab:lab /home/lab/.ssh
    chmod 700 /home/lab/.ssh
    chmod 600 /home/lab/.ssh/authorized_keys
fi

mkdir -p /etc/ssh/config_custom /var/run/sshd

# Banner shown when connecting through the ProxyJump entry point
printf -- '-----------------------\n   PROXY JUMP ONLY     \n-----------------------\n' \
    > /etc/ssh/config_custom/sshd_banner_proxy

# Entry SSHD -- inside router00 ns, LAN-facing, ProxyJump only
cat > /etc/ssh/config_custom/sshd_config_entry << 'ENTRY'
ListenAddress 10.1.10.1
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

Banner /etc/ssh/config_custom/sshd_banner_proxy
MaxSessions 0
PermitTTY no
ForceCommand /bin/false
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
ENTRY

# Host SSHD -- default ns, listens on fmp-d IP, full shell access
cat > /etc/ssh/config_custom/sshd_config_host << HOST
ListenAddress ${ROUTER00_DEFAULT_NS_FMP_D_IP}
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
HOST

# fmp veth: fmp-d in default ns <-> fmp-u in router00 ns
ip link add fmp-d type veth peer name fmp-u        2>/dev/null || true
ip link set fmp-u netns router00                   2>/dev/null || true
ip addr add ${ROUTER00_DEFAULT_NS_FMP_D_IP}/${ROUTER00_NS_FMP_MASK} dev fmp-d 2>/dev/null || true
ip link set fmp-d up
ip netns exec router00 ip addr add \
    ${ROUTER00_ROUTER_NS_FMP_U_IP}/${ROUTER00_NS_FMP_MASK} dev fmp-u 2>/dev/null || true
ip netns exec router00 ip link set fmp-u up

# (Re)start both SSHD instances
pkill -f sshd_config_entry 2>/dev/null || true
pkill -f sshd_config_host  2>/dev/null || true

ip netns exec router00 /usr/sbin/sshd -f /etc/ssh/config_custom/sshd_config_entry
/usr/sbin/sshd -f /etc/ssh/config_custom/sshd_config_host

# Shell prompt and aliases
cat > /root/.profile << 'ROOT_PROF'
export PS1='\h$(N=$(ip netns identify); [ -n "$N" ] && echo "-[\[\e[1;32m\]ns-$N\[\e[0m\]]"):\w\$ '
alias bastion='ip netns exec bastion /bin/ash'
alias router='ip netns exec router00 /bin/ash'
ROOT_PROF

cat > /home/lab/.profile << 'LAB_PROF'
export PS1='\u@\h$(N=$(ip netns identify); [ -n "$N" ] && echo "-[\[\e[1;32m\]ns-$N\[\e[0m\]]"):\w\$ '
alias bastion='sudo ip netns exec bastion /bin/ash'
alias router='sudo ip netns exec router00 /bin/ash'
LAB_PROF
chown lab:lab /home/lab/.profile

MGMT
chmod +x /root/lab/mgmt-access.sh
chmod 700 /root/lab/mgmt-access.sh

# ------------------------------------------------------------------------------
# 6. /etc/dnsmasq-cottage.conf
# ------------------------------------------------------------------------------

echo "==> Writing /etc/dnsmasq-cottage.conf"
cat > /etc/dnsmasq-cottage.conf << 'EOF'
# --- Interface ---
interface=eth0
bind-interfaces
domain=cottage.lab
expand-hosts
local=/cottage.lab/

# --- DHCP (LAN clients and Google Nest) ---
dhcp-range=10.1.10.100,10.1.10.200,24h
dhcp-option=3,10.1.10.1      # Default gateway
dhcp-option=6,10.1.10.1      # DNS server

# --- Domain search list (Option 119) ---
dhcp-option=119,cottage.lab,home.lab

# --- DNS forwarding ---
server=/home.lab/10.0.10.1
server=8.8.8.8
server=1.1.1.1

# --- Static host records ---
host-record=h-server00.home.lab,10.0.10.2
host-record=h-router00.home.lab,10.0.10.1
host-record=h-bastion-wg.home.lab,10.0.0.1
host-record=c-bastion-wg.cottage.lab,10.0.0.2
host-record=c-router00-dmz.cottage.lab,10.1.1.2
host-record=h-router00-dmz.home.lab,10.0.1.2
host-record=h-bastion.home.lab,10.0.1.1
host-record=c-router00.cottage.lab,10.1.10.1

# --- Reverse DNS forwarding to site A ---
server=/0.10.in-addr.arpa/10.0.10.1
EOF

# ------------------------------------------------------------------------------
# 7. /etc/network/interfaces
#    Both physical interfaces are set to manual so network.start owns them.
# ------------------------------------------------------------------------------

echo "==> Writing /etc/network/interfaces"
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

# Integrated RJ45 (eth0) -- moved to router00 namespace by network.start
auto eth0
iface eth0 inet manual

# USB Ethernet dongle (eth1) -- moved to bastion namespace by network.start
auto eth1
iface eth1 inet manual
EOF

# ------------------------------------------------------------------------------
# 8. Recovery helper: /root/lab/interfaces
#    Restore DHCP on both interfaces to regain SSH after a bad network.start.
# ------------------------------------------------------------------------------

echo "==> Writing /root/lab/interfaces (recovery helper)"
cat > /root/lab/interfaces << 'EOF'
# Recovery procedure -- run from console to regain SSH access:
#
#   rm /etc/local.d/network.start
#   rc-update add sshd default
#   cp /root/lab/interfaces /etc/network/interfaces
#   reboot
#
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto eth1
iface eth1 inet dhcp
EOF

# ------------------------------------------------------------------------------
# 9. /root/lab/test.sh -- post-reboot verification helper
# ------------------------------------------------------------------------------

echo "==> Writing /root/lab/test.sh"
cat > /root/lab/test.sh << 'EOF'
#!/bin/ash
# Post-reboot connectivity checks -- run as root after setup

echo "=== Namespaces ==="
ip netns list

echo "=== Bastion WAN ping (8.8.8.8) ==="
ip netns exec bastion ping -c 3 8.8.8.8

echo "=== WireGuard status ==="
ip netns exec bastion wg show

echo "=== Tunnel: ping remote bastion wg0 (10.0.0.1) ==="
ip netns exec bastion ping -c 3 10.0.0.1

echo "=== DMZ: bastion -> router00 (10.1.1.2) ==="
ip netns exec bastion ping -c 3 10.1.1.2

echo "=== DMZ: router00 -> bastion (10.1.1.1) ==="
ip netns exec router00 ping -c 3 10.1.1.1

echo "=== dnsmasq leases ==="
ip netns exec router00 cat /var/lib/misc/dnsmasq.leases 2>/dev/null || echo "(no leases yet)"
EOF
chmod +x /root/lab/test.sh

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------

echo ""
echo "================================================================"
echo "  Setup complete."
echo "  All files written. Rebooting in 5 seconds."
echo "  Ctrl-C to cancel."
echo "================================================================"
sleep 5
reboot
