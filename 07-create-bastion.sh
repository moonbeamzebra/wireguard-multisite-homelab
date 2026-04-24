#!/bin/bash
# 07-create-bastion.sh -- Deploy the WireGuard bastion VM (Alpine)
#
# Usage:
#   source site-A.env && source secrets-A.env && bash 07-create-bastion.sh
#   source site-B.env && source secrets-B.env && bash 07-create-bastion.sh
#
# Required env vars (from site-*.env + secrets-*.env):
#   SITE_NAME, BASTION_VM_NAME, BASTION_HOSTNAME, PRIMARY_DOMAIN
#   BASTION_IP_eth0, BASTION_MASK_eth0, BASTION_GW_eth0
#   BASTION_IP_eth1, BASTION_MASK_eth1
#   WG_ADDR, WG_PRIVATE_KEY, WG_PEER_PUBKEY, WG_PEER_ENDPOINT, WG_ALLOWED_IPS
#   ROUTE1_NET, ROUTE1_GW, ROUTE2_NET, ROUTE2_GW
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD

set -euo pipefail

# -- Validate required variables -----------------------------------------------
REQUIRED_VARS="SITE_NAME BASTION_VM_NAME BASTION_HOSTNAME PRIMARY_DOMAIN
               BASTION_IP_eth0 BASTION_MASK_eth0 BASTION_GW_eth0
               BASTION_IP_eth1 BASTION_MASK_eth1
               WG_ADDR WG_PRIVATE_KEY WG_PEER_PUBKEY WG_PEER_ENDPOINT WG_ALLOWED_IPS
               ROUTE1_NET ROUTE1_GW ROUTE2_NET ROUTE2_GW
               LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD"

MISSING=0
for VAR in $REQUIRED_VARS; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: $VAR"
        MISSING=1
    fi
done
[[ $MISSING -eq 1 ]] && { echo "=> Run: source site-A.env && source secrets-A.env"; exit 1; }

# -- Alpine cloud-init image ---------------------------------------------------
IMAGE_NAME=${ALPINE_EFFECTIVE_IMAGE_TO_USE}

MAC_eth0=$(echo "${BASTION_IP_eth0}" | awk -F. '{printf "52:54:%02x:%02x:%02x:%02x\n", $1, $2, $3, $4}')
MAC_eth1=$(echo "${BASTION_IP_eth1}" | awk -F. '{printf "52:54:%02x:%02x:%02x:%02x\n", $1, $2, $3, $4}')

echo "==> Site       : ${SITE_NAME}"
echo "==> VM         : ${BASTION_VM_NAME}"
echo "==> eth0 WAN   : ${BASTION_IP_eth0}  MAC=${MAC_eth0}"
echo "==> eth1 DMZ   : ${BASTION_IP_eth1}  MAC=${MAC_eth1}"
echo "==> wg0        : ${WG_ADDR}"
echo "==> WG peer    : ${WG_PEER_ENDPOINT}"
echo "==> AllowedIPs : ${WG_ALLOWED_IPS}"
echo "==> Route1     : ${ROUTE1_NET} via ${ROUTE1_GW} dev eth1"
echo "==> Route2     : ${ROUTE2_NET} dev wg0"

CIDATA=/tmp/${BASTION_VM_NAME}-cidata
mkdir -p ${CIDATA}

cat > ${CIDATA}/meta-data << EOF
instance-id: ${BASTION_VM_NAME}
local-hostname: ${BASTION_VM_NAME}
EOF

# -- cloud-init user-data ------------------------------------------------------
cat > ${CIDATA}/user-data.yaml << EOF
#cloud-config
hostname: ${BASTION_HOSTNAME}
timezone: America/Montreal

ssh_pwauth: false

network:
  config: disabled

manage_resolv_conf: true
resolv_conf:
  nameservers:
    - 8.8.8.8
    - 4.4.4.4

users:
  - name: lab
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/ash
    ## TODO: remove lock_passwd once stable
    lock_passwd: false
    ssh_authorized_keys:
      - ${LAB_SSH_PUBKEY}

## TODO: remove chpasswd block once stable
chpasswd:
  expire: false
  users:
    - name: root
      password: ${ROOT_PASSWORD}
      type: text
    - name: lab
      password: ${LAB_PASSWORD}
      type: text

write_files:

  # --- Network: static interfaces ---
  - path: /etc/network/interfaces
    content: |
      auto lo
      iface lo inet loopback

      auto eth0
      iface eth0 inet static
          address ${BASTION_IP_eth0}
          netmask ${BASTION_MASK_eth0}
          gateway ${BASTION_GW_eth0}

      auto eth1
      iface eth1 inet static
          address ${BASTION_IP_eth1}
          netmask ${BASTION_MASK_eth1}

  # --- WireGuard private key ---
  - path: /etc/wireguard/private.key
    content: |
      ${WG_PRIVATE_KEY}
    permissions: '0600'

  # --- WireGuard wg0 config ---
  # ROUTE1 (local LANs)   : via + dev on eth1
  # ROUTE2 (remote site)  : no via on wg0
  #   Point-to-point interface: kernel ignores "via GW",
  #   would produce scope link without a usable next-hop
  - path: /etc/wireguard/wg0.conf
    permissions: '0600'
    content: |
      [Interface]
      Address    = ${WG_ADDR}
      PrivateKey = ${WG_PRIVATE_KEY}
      ListenPort = 51820

      PreUp      = sysctl -w net.ipv4.ip_forward=1
      PostUp     = ip route add ${ROUTE1_NET} via ${ROUTE1_GW} dev eth1 || true
      PostUp     = ip route add ${ROUTE2_NET} dev wg0 || true
      PostDown   = ip route del ${ROUTE1_NET} via ${ROUTE1_GW} dev eth1 || true
      PostDown   = ip route del ${ROUTE2_NET} dev wg0 || true

      [Peer]
      PublicKey           = ${WG_PEER_PUBKEY}
      Endpoint            = ${WG_PEER_ENDPOINT}
      AllowedIPs          = ${WG_ALLOWED_IPS}
      PersistentKeepalive = 25

  # --- sysctl: IP forwarding + disable ICMP redirects ---
  - path: /etc/sysctl.d/10-bastion.conf
    content: |
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.send_redirects=0
      net.ipv4.conf.default.send_redirects=0
      net.ipv4.conf.all.accept_redirects=0
      net.ipv4.conf.default.accept_redirects=0

  # --- iptables rules ---
  #
  # NAT
  #   MASQUERADE on eth0: hides private IPs behind the WAN IP
  #   Required so LAN->internet traffic is returned correctly
  #
  # INPUT: DROP by default
  #   loopback              ACCEPT
  #   ESTABLISHED/RELATED   ACCEPT
  #   UDP 51820 on eth0     ACCEPT  (WireGuard inbound from WAN)
  #   TCP 22    on eth1     ACCEPT  (SSH from DMZ only)
  #   ICMP      on eth1     ACCEPT  (debug ping from DMZ)
  #   ICMP      on wg0      ACCEPT  (debug ping inter-bastion)
  #
  # FORWARD: DROP by default
  #   wg0  -> eth1                  ACCEPT  (inter-site inbound)
  #   eth1 -> wg0                   ACCEPT  (inter-site outbound)
  #   eth1 -> eth0                  ACCEPT  (LAN to internet)
  #   eth0 -> eth1 ESTABLISHED      ACCEPT  (internet replies)
  #
  # Connections initiated from internet: DROP
  - path: /etc/iptables/rules-save
    content: |
      *mangle
      :PREROUTING ACCEPT [0:0]
      :INPUT ACCEPT [0:0]
      :FORWARD ACCEPT [0:0]
      :OUTPUT ACCEPT [0:0]
      :POSTROUTING ACCEPT [0:0]
      # Clamp TCP MSS to Path MTU for all forwarded traffic (WireGuard optimization)
      -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      COMMIT

      *nat
      :PREROUTING ACCEPT [0:0]
      :INPUT ACCEPT [0:0]
      :OUTPUT ACCEPT [0:0]
      :POSTROUTING ACCEPT [0:0]
      -A POSTROUTING -o eth0 -j MASQUERADE
      COMMIT

      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]

      -A INPUT -i lo -j ACCEPT
      -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      -A INPUT -i eth0 -p udp --dport 51820 -j ACCEPT
      -A INPUT -i eth1 -p tcp --dport 22 -j ACCEPT
      -A INPUT -i eth1 -p icmp -j ACCEPT
      -A INPUT -i wg0  -p icmp -j ACCEPT

      -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
      -A FORWARD -i wg0  -o eth1 -j ACCEPT
      -A FORWARD -i eth1 -o wg0  -j ACCEPT
      -A FORWARD -i eth1 -o eth0 -j ACCEPT
      -A FORWARD -i eth0 -o eth1 -m state --state ESTABLISHED,RELATED -j ACCEPT

      COMMIT

  # --- SSH hardening ---
  # Key-only access, root login disabled
  # SSH accessible from eth1 (DMZ) only via iptables
  - path: /etc/ssh/sshd_config.d/bastion.conf
    content: |
      PasswordAuthentication no
      PermitRootLogin no
      X11Forwarding no
      AllowTcpForwarding no
      MaxAuthTries 3

runcmd:
  - rc-update add networking boot
  - rc-service networking restart
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf
  - apk add --no-cache wireguard-tools iptables dnsmasq iptables-openrc sudo htop
  - sysctl -p /etc/sysctl.d/10-bastion.conf
  - chmod 600 /etc/wireguard/private.key
  - chmod 600 /etc/wireguard/wg0.conf

  # Fix wg-quick OpenRC: symlink required since Alpine 3.23
  - ln -s /etc/init.d/wg-quick /etc/init.d/wg-quick.wg0
  - rc-update add wg-quick.wg0 default

  # Fix iptables: force legacy (virtualised kernel lacks nf_tables)
  # package_upgrade installs iptables nf_tables which fails at boot
  - ln -sf /sbin/iptables-legacy         /sbin/iptables
  - ln -sf /sbin/iptables-legacy-restore /sbin/iptables-restore
  - ln -sf /sbin/iptables-legacy-save    /sbin/iptables-save
  - rc-update add iptables default
  - /etc/init.d/iptables start

  - rc-service networking restart
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf
  - touch /etc/cloud/cloud-init.disabled
  - rc-update del cloud-init default 2>/dev/null || true
  - rc-update del cloud-config default 2>/dev/null || true
  - rc-update del cloud-final default 2>/dev/null || true

  - sysctl -w net.ipv6.conf.all.disable_ipv6=1
  - sysctl -w net.ipv6.conf.default.disable_ipv6=1
  - sysctl -w net.ipv6.conf.lo.disable_ipv6=1
  - echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.d/00-disable-ipv6.conf
  - echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/00-disable-ipv6.conf
  - echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.d/00-disable-ipv6.conf

  # Reboot required after package_upgrade: new kernel installed
  # WireGuard and iptables-legacy work correctly after reboot
  - reboot
EOF

sudo virsh destroy ${BASTION_VM_NAME} 2>/dev/null || true
sudo virsh undefine ${BASTION_VM_NAME} --remove-all-storage 2>/dev/null || true

sudo cloud-localds /var/lib/libvirt/images/${BASTION_VM_NAME}-cidata.iso \
    ${CIDATA}/user-data.yaml \
    ${CIDATA}/meta-data

sudo cp /var/lib/libvirt/images/iso/${IMAGE_NAME} \
        /var/lib/libvirt/images/${BASTION_VM_NAME}.qcow2
sudo qemu-img resize /var/lib/libvirt/images/${BASTION_VM_NAME}.qcow2 6G

virt-install \
    --name ${BASTION_VM_NAME} \
    --memory 256 \
    --vcpus 1 \
    --os-variant alpinelinux3.17 \
    --disk path=/var/lib/libvirt/images/${BASTION_VM_NAME}.qcow2,format=qcow2 \
    --disk path=/var/lib/libvirt/images/${BASTION_VM_NAME}-cidata.iso,device=cdrom \
    --network network=${NET_Bastion_eth0},mac=${MAC_eth0} \
    --network network=lan-dmz,mac=${MAC_eth1} \
    --graphics none \
    --import \
    --noautoconsole \
    --memorybacking nosharepages=yes \
    --cputune shares=4096

virsh autostart ${BASTION_VM_NAME}

echo ""
echo "==> VM ${BASTION_VM_NAME} created"
echo "    Boot 1: update/upgrade/reboot (~90s)"
echo "    Boot 2: WireGuard + iptables operational"
echo ""
echo "==> Monitor with:"
echo "    virsh console ${BASTION_VM_NAME}"
echo ""
echo "==> Sanity checks after boot 2:"
echo ""
echo "# Basic networking"
echo "ip a && ip r"
echo ""
echo "# WireGuard -- verify: recent handshake, non-zero transfer, correct AllowedIPs"
echo "sudo wg show"
echo ""
echo "# Tunnel connectivity"
echo "ping -c 3 ${ROUTE2_GW}       # remote bastion wg0"
echo ""
echo "# DMZ connectivity (toward router00)"
echo "ping -c 3 ${ROUTE1_GW}       # router00 DMZ IP"
echo ""
echo "# Internet"
echo "ping -c 3 8.8.8.8 && ping -c 3 google.com"
echo ""
echo "# iptables -- verify: INPUT DROP default, UDP 51820 on eth0, SSH on eth1, MASQUERADE"
echo "sudo iptables -L -n -v"
echo "sudo iptables -t nat -L -n -v"
