#!/bin/bash
# 08-create-bastion.sh -- Deploy the WireGuard bastion VM (Alpine)
#
# Usage:
#   source site-A.env && source site-A-secrets.env && bash 08-create-bastion.sh
#   source site-B.env && source site-B-secrets.env && bash 08-create-bastion.sh
#
# Required env vars (from site-*.env + site-*-secrets.env):
#   SITE_NAME, BASTION_VM_NAME, BASTION_HOSTNAME, PRIMARY_DOMAIN
#   BASTION_IP_eth0, BASTION_MASK_eth0, BASTION_GW_eth0
#   BASTION_IP_eth1, BASTION_MASK_eth1
#   WG_ADDR, WG_LISTEN_PORT
#   WG_PRIVATE_KEY, WG_PEER_PUBKEY, WG_PEER_ENDPOINT, WG_ALLOWED_IPS
#   ROUTE1_NET, ROUTE1_GW, ROUTE2_NET, ROUTE2_GW
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD

set -euo pipefail

REQUIRED_VARS="SITE_NAME BASTION_VM_NAME BASTION_HOSTNAME PRIMARY_DOMAIN
               BASTION_IP_eth0 BASTION_MASK_eth0 BASTION_GW_eth0
               BASTION_IP_eth1 BASTION_MASK_eth1
               WG_ADDR WG_LISTEN_PORT
               WG_PRIVATE_KEY WG_PEER_PUBKEY WG_PEER_ENDPOINT WG_ALLOWED_IPS
               ROUTE1_NET ROUTE1_GW ROUTE2_NET ROUTE2_GW
               LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD NET_Bastion_eth0"

MISSING=0
for VAR in $REQUIRED_VARS; do
    if [[ -z "${!VAR:-}" ]]; then echo "ERROR: missing variable: $VAR"; MISSING=1; fi
done
[[ $MISSING -eq 1 ]] && { echo "=> Run: source site-A.env && source site-A-secrets.env"; exit 1; }

IMAGE_NAME=${ALPINE_EFFECTIVE_IMAGE_TO_USE}

# Deterministic MAC: md5( "${SITE_NAME}::${BASTION_VM_NAME}" ), first 4 bytes
_mac() {
    local key="$1"
    local hash
    hash=$(echo -n "${key}" | md5sum | awk '{print $1}')
    echo "52:54:${hash:0:2}:${hash:2:2}:${hash:4:2}:${hash:6:2}"
}
MAC_eth0=$(_mac "${SITE_NAME}::${BASTION_VM_NAME}-eth0")
MAC_eth1=$(_mac "${SITE_NAME}::${BASTION_VM_NAME}-eth1")

echo "==> Site       : ${SITE_NAME}"
echo "==> VM         : ${BASTION_VM_NAME}"
echo "==> eth0 WAN   : ${BASTION_IP_eth0}  MAC=${MAC_eth0}"
echo "==> eth1 DMZ   : ${BASTION_IP_eth1}  MAC=${MAC_eth1}"
echo "==> wg0        : ${WG_ADDR}  ListenPort=${WG_LISTEN_PORT}"
echo "==> WG peer    : ${WG_PEER_ENDPOINT}"

CIDATA=/tmp/${BASTION_VM_NAME}-cidata
mkdir -p ${CIDATA}

cat > ${CIDATA}/meta-data << EOF
instance-id: ${BASTION_VM_NAME}
local-hostname: ${BASTION_HOSTNAME}
EOF

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
    lock_passwd: false
    ssh_authorized_keys:
      - ${LAB_SSH_PUBKEY}

chpasswd:
  expire: false
  users:
    - {name: root, password: "${ROOT_PASSWORD}", type: text}
    - {name: lab, password: "${LAB_PASSWORD}", type: text}

write_files:
  - path: /etc/network/interfaces
    content: |
      auto lo
      iface lo inet loopback

      auto eth0
      iface eth0 inet static
          address ${BASTION_IP_eth0}
          netmask ${BASTION_MASK_eth0}
          gateway ${BASTION_GW_eth0}
          post-up ethtool -K eth0 tx on sg on tso on gso on gro on lro on || true
          post-up ethtool -C eth0 rx-usecs 0 || true

      auto eth1
      iface eth1 inet static
          address ${BASTION_IP_eth1}
          netmask ${BASTION_MASK_eth1}
          post-up ethtool -K eth1 tx on sg on tso on gso on gro on lro on || true
          post-up ethtool -C eth1 rx-usecs 0 || true

  - path: /etc/wireguard/private.key
    content: "${WG_PRIVATE_KEY}"
    permissions: '0600'

  - path: /etc/wireguard/wg0.conf
    permissions: '0600'
    content: |
      [Interface]
      Address    = ${WG_ADDR}
      PrivateKey = ${WG_PRIVATE_KEY}
      ListenPort = ${WG_LISTEN_PORT}
      MTU        = 1420
      PreUp      = sysctl -w net.ipv4.ip_forward=1
      PostUp     = ip route add ${ROUTE1_NET} via ${ROUTE1_GW} dev eth1 || true
      PostUp     = ip route add ${ROUTE2_NET} dev wg0 || true

      [Peer]
      PublicKey           = ${WG_PEER_PUBKEY}
      Endpoint            = ${WG_PEER_ENDPOINT}
      AllowedIPs          = ${WG_ALLOWED_IPS}
      PersistentKeepalive = 25

  - path: /etc/sysctl.d/10-bastion.conf
    content: |
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.send_redirects=0
      net.ipv4.conf.default.send_redirects=0

  - path: /etc/iptables/rules-save
    content: |
      *mangle
      :PREROUTING ACCEPT [0:0]
      :FORWARD ACCEPT [0:0]
      # Clamp TCP MSS to path MTU to prevent stalls through the WireGuard tunnel
      -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      COMMIT
      *nat
      :POSTROUTING ACCEPT [0:0]
      # NAT outbound traffic leaving through the WAN interface
      -A POSTROUTING -o eth0 -j MASQUERADE
      COMMIT
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      -A INPUT -i lo -j ACCEPT
      -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      # WireGuard UDP from ISP
      -A INPUT -i eth0 -p udp --dport ${WG_LISTEN_PORT} -j ACCEPT
      # SSH and ICMP from DMZ (router00) and WireGuard tunnel (inter-site management)
      -A INPUT -i eth1 -p tcp --dport 22 -j ACCEPT
      -A INPUT -i eth1 -p icmp -j ACCEPT
      -A INPUT -i wg0  -p tcp --dport 22 -j ACCEPT
      -A INPUT -i wg0  -p icmp -j ACCEPT
      # Forward: tunnel <-> DMZ <-> WAN
      -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
      -A FORWARD -i wg0  -o eth1 -j ACCEPT
      -A FORWARD -i eth1 -o wg0  -j ACCEPT
      -A FORWARD -i eth1 -o eth0 -j ACCEPT
      -A FORWARD -i eth0 -o eth1 -m state --state ESTABLISHED,RELATED -j ACCEPT
      COMMIT

  - path: /etc/ssh/sshd_config.d/bastion.conf
    content: |
      PasswordAuthentication no
      PermitRootLogin no
      X11Forwarding no
      # AllowTcpForwarding yes: required for SSH ProxyJump through this host
      # (Mac -> server00 -> bastion -> VMs on the remote site)
      AllowTcpForwarding yes
      MaxAuthTries 3

  - path: /etc/motd
    content: |
      ================================================================================
        BASTION WIREGUARD - SITE: ${SITE_NAME^^}
      ================================================================================
        Purpose: WireGuard VPN gateway and WAN NAT

        QUICK SANITY CHECKS:
        --------------------
        1. Networking  : ip a && ip r
        2. VPN Status  : sudo wg show
        3. Tunnel ping : ping -c 3 ${ROUTE2_GW}
        4. DMZ ping    : ping -c 3 ${ROUTE1_GW}
        5. Internet    : ping -c 3 8.8.8.8
        6. Services    : rc-status -s

        FIREWALL / NAT:
        ---------------
        sudo iptables -L -n -v
        sudo iptables -t nat -L -n -v

        IPERF3 THROUGHPUT TEST (requires iperf3 installed on both demo VMs):
        On remote site: iperf3 -s
        On this site:   iperf3 -c <remote-demo-vm-IP>
      ================================================================================

runcmd:
  - rc-update add networking boot
  - rc-service networking restart
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf
  - apk add --no-cache wireguard-tools iptables iptables-openrc sudo htop ethtool acpid
  - sysctl -p /etc/sysctl.d/10-bastion.conf
  - chmod 600 /etc/wireguard/private.key
  - chmod 600 /etc/wireguard/wg0.conf

  # wg-quick requires a per-tunnel symlink on Alpine 3.23+
  - ln -s /etc/init.d/wg-quick /etc/init.d/wg-quick.wg0
  - rc-update add wg-quick.wg0 default

  # Force iptables-legacy (required for compatibility with the running kernel)
  - ln -sf /sbin/iptables-legacy         /sbin/iptables
  - ln -sf /sbin/iptables-legacy-restore /sbin/iptables-restore
  - ln -sf /sbin/iptables-legacy-save    /sbin/iptables-save
  - rc-update add iptables default

  - rc-update add acpid default

  # bastion uses static networking -- dhcpcd (DHCP client) is not needed.
  # Disabling it prevents it from overwriting /etc/resolv.conf.
  - rc-update del dhcpcd default 2>/dev/null || true
  - rc-service dhcpcd stop   2>/dev/null || true
  - apk del dhcpcd 2>/dev/null || true
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf

  # Disable IPv6: dhcpcd.conf prevents DHCPv6, update-extlinux disables at kernel level
  - echo "noipv6" >> /etc/dhcpcd.conf
  - sed -i 's/default_kernel_opts="/default_kernel_opts="ipv6.disable=1 /' /etc/update-extlinux.conf
  - update-extlinux
  - sed -i 's/^net.ipv6/#net.ipv6/' /usr/lib/sysctl.d/00-alpine.conf

  - touch /etc/cloud/cloud-init.disabled
  - rc-update del cloud-init          default 2>/dev/null || true
  - rc-update del cloud-config        default 2>/dev/null || true
  - rc-update del cloud-final         default 2>/dev/null || true
  - rc-update del cloud-init-hotplugd default 2>/dev/null || true
  - reboot
EOF

sudo virsh destroy  ${BASTION_VM_NAME} 2>/dev/null || true
sudo virsh undefine ${BASTION_VM_NAME} --remove-all-storage 2>/dev/null || true

sudo cloud-localds /var/lib/libvirt/images/${BASTION_VM_NAME}-cidata.iso \
    ${CIDATA}/user-data.yaml ${CIDATA}/meta-data

sudo cp /var/lib/libvirt/images/iso/${IMAGE_NAME} \
        /var/lib/libvirt/images/${BASTION_VM_NAME}.qcow2
sudo qemu-img resize /var/lib/libvirt/images/${BASTION_VM_NAME}.qcow2 6G

# cpu host-passthrough exposes AES-NI to the guest for WireGuard acceleration.
# driver.name=vhost offloads virtio-net to the host kernel for lower CPU usage.
virt-install \
    --name ${BASTION_VM_NAME} \
    --memory 256 \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant alpinelinux3.21 \
    --disk path=/var/lib/libvirt/images/${BASTION_VM_NAME}.qcow2,format=qcow2 \
    --disk path=/var/lib/libvirt/images/${BASTION_VM_NAME}-cidata.iso,device=cdrom \
    --network network=${NET_Bastion_eth0},mac=${MAC_eth0},model=virtio,driver.name=vhost,driver.queues=2 \
    --network network=lan-dmz,mac=${MAC_eth1},model=virtio,driver.name=vhost,driver.queues=2 \
    --graphics none \
    --import \
    --noautoconsole \
    --memorybacking nosharepages=yes,locked=yes \
    --cputune vcpupin0.vcpu=0,vcpupin0.cpuset=2,vcpupin1.vcpu=1,vcpupin1.cpuset=3,shares=4096

virsh autostart ${BASTION_VM_NAME}
rm -rf ${CIDATA}

echo ""
echo "==> ${BASTION_VM_NAME} created -- cloud-init reboot in ~90s"
echo "    virsh console ${BASTION_VM_NAME}"
echo ""
echo "    Verify after reboot:"
echo "    sudo wg show                      # expect: recent handshake"
echo "    ping -c 3 ${ROUTE2_GW}            # remote bastion wg0"
echo "    ping -c 3 ${ROUTE1_GW}            # router00 DMZ"
echo "    sudo iptables -L -n -v"
