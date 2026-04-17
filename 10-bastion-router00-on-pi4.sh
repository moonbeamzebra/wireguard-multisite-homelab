###################
## LOGIN AS ROOT ##
###################
su -
<root password>

#################################
## CREATE REQUIRED DIRECTORIES ##
#################################
mkdir -p /root/lab /etc/wireguard /etc/local.d

##############
## PACKAGES ##
##############
# Allow sudo to install: activate community repo
sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories
apk update
apk add wireguard-tools iproute2 dnsmasq iptables tcpdump htop sudo
# Disable community repo
sed -i 's/\(.*\/community\)/#\1/' /etc/apk/repositories
# Clean apk cache
rm -rf /var/cache/apk/*

################################
## /etc/local.d/network.start ##
################################
cat > /etc/local.d/network.start << 'EOF'
#!/bin/ash

# --- 1. Environment & Prerequisites ---
source /root/lab/site-B-pi4.env
source /root/lab/secrets-B-pi4.env
modprobe wireguard
modprobe tun

# --- 2. Cleanup existing Namespaces ---
ip netns del bastion 2>/dev/null || true
ip netns del router00 2>/dev/null || true

# --- 3. Namespaces & VETH Creation ---
# Note: VETH names are limited to 15 chars (Linux IFNAMSIZ)
ip netns add bastion
ip netns add router00
ip link add v-bastion type veth peer name v-router00
ip link set v-bastion netns bastion
ip link set v-router00 netns router00

# Set distinct hostnames for each namespace (useful for SSH/Prompt)
ip netns exec bastion hostname ${BASTION_HOSTNAME}
ip netns exec router00 hostname ${ROUTER00_HOSTNAME}

# --- 4. BASTION CONFIGURATION ---
# Physical WAN (USB Dongle)
ip link set ${IF_WAN} netns bastion
ip netns exec bastion ip addr add ${BASTION_IP_eth0}/${BASTION_MASK_eth0} dev ${IF_WAN}
ip netns exec bastion ip link set ${IF_WAN} up
ip netns exec bastion ip route add default via ${BASTION_GW_eth0}

# DMZ Link (veth)
ip netns exec bastion ip addr add ${BASTION_IP_eth1}/30 dev v-bastion
ip netns exec bastion ip link set v-bastion up
ip netns exec bastion ip link set lo up
# Scope link route to ensure DMZ is reachable locally
ip netns exec bastion ip route add 10.1.1.0/30 dev v-bastion scope link

# --- 5. ROUTER00 CONFIGURATION ---
# Physical LAN (Integrated RJ45)
ip link set ${IF_LAN} netns router00
ip netns exec router00 ip addr add ${ROUTER00_IP_eth1}/24 dev ${IF_LAN}
ip netns exec router00 ip link set ${IF_LAN} up

# DMZ Link (veth)
ip netns exec router00 ip addr add ${ROUTER00_IP_eth0}/30 dev v-router00
ip netns exec router00 ip link set v-router00 up
ip netns exec router00 ip link set lo up
ip netns exec router00 ip route add default via ${ROUTER00_GW_eth0}
# Scope link route to ensure DMZ is reachable locally
ip netns exec router00 ip route add 10.1.1.0/30 dev v-router00 scope link

# --- 6. VPN & FORWARDING (Manual WG Setup) ---
# Enable IP Forwarding
ip netns exec bastion sysctl -w net.ipv4.ip_forward=1
ip netns exec router00 sysctl -w net.ipv4.ip_forward=1

# Manual WireGuard Interface Setup (bypass wg-quick issues in netns)
ip netns exec bastion ip link add dev wg0 type wireguard
ip netns exec bastion wg setconf wg0 /etc/wireguard/wg0-core.conf
ip netns exec bastion ip addr add ${WG_ADDR} dev wg0
ip netns exec bastion ip link set wg0 up

# Manual Static Routes for Tunnel
ip netns exec bastion ip route add 10.0.0.0/16 dev wg0
ip netns exec bastion ip route add 10.1.0.0/16 via ${ROUTER00_IP_eth0}

# --- 7. SERVICES (DNS & SSH) ---
# DNS Server in Router00
ip netns exec router00 dnsmasq --conf-file=/etc/dnsmasq-cottage.conf


# --- 8. IPTABLES - BASTION ---
ip netns exec bastion iptables -F
ip netns exec bastion iptables -t nat -F
ip netns exec bastion iptables -P INPUT DROP
ip netns exec bastion iptables -P FORWARD DROP

# NAT: WAN outbound
ip netns exec bastion iptables -t nat -A POSTROUTING -o ${IF_WAN} -j MASQUERADE
# INPUT: Standard rules + WG + DMZ SSH
ip netns exec bastion iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec bastion iptables -A INPUT -i lo -j ACCEPT
ip netns exec bastion iptables -A INPUT -i ${IF_WAN} -p udp --dport 51820 -j ACCEPT
ip netns exec bastion iptables -A INPUT -i v-bastion -p icmp -j ACCEPT
ip netns exec bastion iptables -A INPUT -i v-bastion -p tcp --dport 22 -j ACCEPT
# FORWARD: Tunnel <-> DMZ <-> WAN
ip netns exec bastion iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec bastion iptables -A FORWARD -i wg0 -o v-bastion -j ACCEPT
ip netns exec bastion iptables -A FORWARD -i v-bastion -o wg0 -j ACCEPT
ip netns exec bastion iptables -A FORWARD -i v-bastion -o ${IF_WAN} -j ACCEPT

# Force TCP MSS to match the tunnel MTU (prevents web browsing stalls)
ip netns exec bastion iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu


# --- 9. IPTABLES - ROUTER00 ---
ip netns exec router00 iptables -F
ip netns exec router00 iptables -P INPUT DROP
ip netns exec router00 iptables -P FORWARD DROP

# INPUT: Standard rules + DHCP/DNS + SSH
ip netns exec router00 iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec router00 iptables -A INPUT -i lo -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p udp --dport 67:68 -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p udp --dport 53 -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p tcp --dport 53 -j ACCEPT
ip netns exec router00 iptables -A INPUT -i ${IF_LAN} -p tcp --dport 22 -j ACCEPT
ip netns exec router00 iptables -A INPUT -i v-router00 -j ACCEPT
# FORWARD: LAN <-> DMZ
ip netns exec router00 iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
ip netns exec router00 iptables -A FORWARD -i ${IF_LAN} -o v-router00 -j ACCEPT
ip netns exec router00 iptables -A FORWARD -i v-router00 -o ${IF_LAN} -j ACCEPT

# Disable Alpine's native SSH
# SSH access is control via /root/lab/mgmt-access.sh
# See below
rc-update del sshd default

# --- Management Access ---
# Comment the line below to lock down the Pi (Console access only)
/root/lab/mgmt-access.sh

EOF

chmod +x /etc/local.d/network.start
rc-update add local default

##############################
## /root/lab/mgmt-access.sh ##
##############################
cat > /root/lab/mgmt-access.sh << 'EOF'
#!/bin/ash

# --- 0. Prerequisites & Sudo Setup ---
# Load environment variables for SSH keys
if [ -f /root/lab/secrets-B-pi4.env ]; then
    source /root/lab/secrets-B-pi4.env
fi

# Generate SSH Host Keys if they don't exist (required for sshd to start)
ssh-keygen -A

# Configure sudo for 'lab' user (no password required)
echo "lab ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/lab
chmod 0440 /etc/sudoers.d/lab

# Setup authorized_keys for 'lab' user
if [ -n "$LAB_SSH_PUBKEY" ]; then
    mkdir -p /home/lab/.ssh
    echo "$LAB_SSH_PUBKEY" > /home/lab/.ssh/authorized_keys
    chown -R lab:lab /home/lab/.ssh
    chmod 700 /home/lab/.ssh
    chmod 600 /home/lab/.ssh/authorized_keys
fi

# --- 1. SSH Configuration Files ---
mkdir -p /etc/ssh/config_custom
mkdir -p /var/run/sshd

# Create the ProxyJump warning banner
echo "-----------------------" > /etc/ssh/config_custom/sshd_banner_proxy
echo "   PROXY JUMP ONLY     " >> /etc/ssh/config_custom/sshd_banner_proxy
echo "-----------------------" >> /etc/ssh/config_custom/sshd_banner_proxy

# Entry point SSHD (in router00 namespace) - Strictly for ProxyJump
cat > /etc/ssh/config_custom/sshd_config_entry << 'ENTRY'
ListenAddress 10.1.10.1
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Lockdown: No shell, no TTY, only TCP forwarding
Banner /etc/ssh/config_custom/sshd_banner_proxy
MaxSessions 0
PermitTTY no
ForceCommand /bin/false
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
ENTRY

# Destination SSHD (on the Host) - Shell access allowed here
cat > /etc/ssh/config_custom/sshd_config_host << HOST
ListenAddress ${ROUTER00_DEFAULT_NS_FMP_D_IP}
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Allow 'lab' user to log in via key
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
HOST

# --- 2. Emergency Host Access (VETH Pair) ---
ip link add fmp-d type veth peer name fmp-u 2>/dev/null
ip link set fmp-u netns router00 2>/dev/null
ip addr add ${ROUTER00_DEFAULT_NS_FMP_D_IP}/${ROUTER00_NS_FMP_MASK} dev fmp-d 2>/dev/null
ip link set fmp-d up
ip netns exec router00 ip addr add ${ROUTER00_ROUTER_NS_FMP_U_IP}/${ROUTER00_NS_FMP_MASK} dev fmp-u 2>/dev/null
ip netns exec router00 ip link set fmp-u up

# --- 3. Start SSH Services ---
pkill -f sshd_config_entry
pkill -f sshd_config_host

ip netns exec router00 /usr/sbin/sshd -f /etc/ssh/config_custom/sshd_config_entry
/usr/sbin/sshd -f /etc/ssh/config_custom/sshd_config_host

# --- 4. User Profiles & Aliases ---
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

EOF
chmod +x /root/lab/mgmt-access.sh
chmod 700 /root/lab/mgmt-access.sh

###############################
## /etc/dnsmasq-cottage.conf ##
###############################
cat > /etc/dnsmasq-cottage.conf << 'EOF'
# --- Interface and Networking ---
interface=eth0
bind-interfaces
domain=cottage.lab
expand-hosts
# Answer queries for this domain from /etc/hosts or static-records only
local=/cottage.lab/

# --- DHCP Pool for Google Nest ---
dhcp-range=10.1.10.100,10.1.10.200,24h
dhcp-option=3,10.1.10.1      # Gateway
dhcp-option=6,10.1.10.1      # DNS

# --- Domain Search List (Option 119) ---
# This tells clients to search both domains
dhcp-option=119,cottage.lab,home.lab

# --- DNS Forwarding to Site Home (A) ---
server=/home.lab/10.0.10.1
# Upstream Public DNS
server=8.8.8.8
server=1.1.1.1

# --- Static Host Records ---
host-record=h-server00.home.lab,10.0.10.2
host-record=h-router00.home.lab,10.0.10.1
host-record=h-bastion-wg.home.lab,10.0.0.1
host-record=c-bastion-wg.cottage.lab,10.0.0.2
host-record=c-router00-dmz.cottage.lab,10.1.1.2
host-record=h-router00-dmz.home.lab,10.0.1.2
host-record=h-bastion.home.lab,10.0.1.1
host-record=c-router00.cottage.lab,10.1.10.1

# --- Reverse DNS Forwarding ---
server=/0.10.in-addr.arpa/10.0.10.1
EOF

##############################
## /root/lab/site-B-pi4.env ##
##############################
# cp site-B-pi4-simulationAtHome.env /root/lab/site-B-pi4.env
# OR
cp site-B-pi4-atCottage.env /root/lab/site-B-pi4.env

#############################
## /etc/wireguard/wg0.conf ##
#############################
##################################
## /etc/wireguard/wg0-core.conf ##
##################################
# wg0-core.conf has secret info - copy-paste secrets-pi4-wg0-core.conf (from secrets-pi4-wg0-core.conf.template)
# No environment variables in it ; variables must be already resolved (values)
vi /etc/wireguard/wg0-core.conf
chmod 600 /etc/wireguard/wg0-core.conf


#################################
## /root/lab/secrets-B-pi4.env ##
#################################
# secrets-B-pi4.env has secret info - copy-paste secrets-B-pi4.env (from secrets-B-pi4.env.template)
# No environment variables in it ; variables must be already resolved (values)
vi /root/lab/secrets-B-pi4.env
chmod 600 /root/lab/secrets-B-pi4.env

#################################################
## EMPTY /etc/network/interfaces BEFORE REBOOT ##
#################################################
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

# Integrated RJ45 port (Toward Google Nest WAN)
auto eth0
iface eth0 inet manual

# USB Ethernet dongle (Toward ISP Modem)
auto eth1
iface eth1 inet manual
EOF

#################################################################
## Keep a working version to be able to ssh in it just in case ##
#################################################################
cat > /root/lab/interfaces << 'EOF'
################################
## rm /etc/local.d/network.start
## sudo rc-update add sshd default
## cp /root/lab/interfaces /etc/network/interfaces
## reboot
################################

auto lo
iface lo inet loopback

# Integrated RJ45 port (Toward Google Nest WAN)
auto eth0
iface eth0 inet manual

# USB Ethernet dongle (Toward ISP Modem)
auto eth1
iface eth1 inet dhcp

EOF


############
## REBOOT ##
############
reboot

###########
## TESTS ##
###########

cat > /root/lab/test.sh << 'EOF'
# --- 1. Check if namespaces are alive ---
ip netns list

# --- 2. Check Bastion WAN connectivity ---
ip netns exec bastion ping -c 3 8.8.8.8

# --- 3. Check WireGuard status (Inside the namespace) ---
# This will show you the "latest handshake"
ip netns exec bastion wg show

# --- 4. Test Tunnel Connectivity ---
# Ping the remote bastion (Site A)
ip netns exec bastion ping -c 3 10.0.0.1

# --- 5. Check Router00 LAN and DMZ ---
# Ping the bastion's DMZ interface from the router namespace
ip netns exec router00 ping -c 3 10.1.1.1

# Ping router00 in router namespace
ip netns exec bastion ping -c 3 10.1.1.2

# Ping site A
ip netns exec bastion ping -c 3 10.0.0.1

# --- 6. Check if Google Nest has received an IP ---
# Look at dnsmasq leases
ip netns exec router00 cat /var/lib/misc/dnsmasq.leases
EOF
chmod +x /root/lab/test.sh