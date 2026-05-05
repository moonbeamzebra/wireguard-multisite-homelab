#!/bin/bash
# 09-create-router00.sh -- Deploy the router00 VM (Alpine -- DHCP/DNS/inter-VLAN routing)
#
# Usage:
#   source site-A.env && source site-A-secrets.env && bash 09-create-router00.sh
#   source site-B.env && source site-B-secrets.env && bash 09-create-router00.sh
#
# Required env vars (from site-*.env + site-*-secrets.env):
#   SITE_NAME, ROUTER00_VM_NAME, ROUTER00_HOSTNAME, PRIMARY_DOMAIN
#   ROUTER00_IP_eth0/eth1/eth2_20/eth2_30/eth3 and their masks/gateways
#   DHCP_LAN{5,10}_START/END, DHCP_VLAN{20,30}_START/END
#   DNS_REMOTE_DOMAIN, DNS_REMOTE_SERVER, DNS_REMOTE_REVERSE, DNS_REMOTE_REVERSE_SERVER
#   DNS_STATIC, DHCP_STATIC_HOSTS
#   IPTABLES_ETH0_ACCEPT_1, IPTABLES_ETH0_ACCEPT_2
#   NET_eth0, NET_eth1_portgroup, NET_eth2_portgroup, NET_eth3_portgroup
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD

set -euo pipefail

REQUIRED_VARS="SITE_NAME ROUTER00_VM_NAME ROUTER00_HOSTNAME PRIMARY_DOMAIN
               ROUTER00_IP_eth0 ROUTER00_MASK_eth0 ROUTER00_GW_eth0
               ROUTER00_IP_eth1 ROUTER00_MASK_eth1
               ROUTER00_IP_eth2_20 ROUTER00_IP_eth2_30
               ROUTER00_IP_eth3
               DHCP_LAN5_START DHCP_LAN5_END
               DHCP_LAN10_START DHCP_LAN10_END
               DHCP_VLAN20_START DHCP_VLAN20_END
               DHCP_VLAN30_START DHCP_VLAN30_END
               DNS_REMOTE_DOMAIN DNS_REMOTE_SERVER
               DNS_REMOTE_REVERSE DNS_REMOTE_REVERSE_SERVER
               DNS_STATIC DHCP_STATIC_HOSTS
               IPTABLES_ETH0_ACCEPT_1 IPTABLES_ETH0_ACCEPT_2
               NET_eth0 NET_eth1_portgroup NET_eth2_portgroup NET_eth3_portgroup
               LAB_SSH_PUBKEY LAB_PASSWORD ROOT_PASSWORD"

MISSING=0
for VAR in $REQUIRED_VARS; do
    if [[ -z "${!VAR:-}" ]]; then echo "ERROR: missing variable: $VAR"; MISSING=1; fi
done
[[ $MISSING -eq 1 ]] && { echo "=> Run: source site-A.env && source site-A-secrets.env"; exit 1; }

IMAGE_NAME=${ALPINE_EFFECTIVE_IMAGE_TO_USE}

# Deterministic MAC: md5( "${SITE_NAME}::${ROUTER00_VM_NAME}-ethN" ), first 4 bytes
_mac() {
    local hash
    hash=$(echo -n "$1" | md5sum | awk '{print $1}')
    echo "52:54:${hash:0:2}:${hash:2:2}:${hash:4:2}:${hash:6:2}"
}
MAC_eth0=$(_mac "${SITE_NAME}::${ROUTER00_VM_NAME}-eth0")
MAC_eth1=$(_mac "${SITE_NAME}::${ROUTER00_VM_NAME}-eth1")
MAC_eth2=$(_mac "${SITE_NAME}::${ROUTER00_VM_NAME}-eth2")
MAC_eth3=$(_mac "${SITE_NAME}::${ROUTER00_VM_NAME}-eth3")

echo "==> Site       : ${SITE_NAME}"
echo "==> VM         : ${ROUTER00_VM_NAME}"
echo "==> eth0 DMZ   : ${ROUTER00_IP_eth0}  GW=${ROUTER00_GW_eth0}  MAC=${MAC_eth0}"
echo "==> eth1 LAN10 : ${ROUTER00_IP_eth1}  MAC=${MAC_eth1}"
echo "==> eth2 trunk : VLAN20=${ROUTER00_IP_eth2_20}  VLAN30=${ROUTER00_IP_eth2_30}  MAC=${MAC_eth2}"
echo "==> eth3 LAN5  : ${ROUTER00_IP_eth3}  MAC=${MAC_eth3}"

CIDATA=/tmp/${ROUTER00_VM_NAME}-cidata
mkdir -p ${CIDATA}

cat > ${CIDATA}/meta-data << EOF
instance-id: ${ROUTER00_VM_NAME}
local-hostname: ${ROUTER00_VM_NAME}
EOF

cat > ${CIDATA}/user-data.yaml << EOF
#cloud-config
hostname: ${ROUTER00_HOSTNAME}
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
          address ${ROUTER00_IP_eth0}
          netmask ${ROUTER00_MASK_eth0}
          gateway ${ROUTER00_GW_eth0}
          post-up ethtool -K eth0 tx on sg on tso on gso on gro on lro on || true
          post-up ethtool -C eth0 rx-usecs 0 || true

      auto eth1
      iface eth1 inet static
          address ${ROUTER00_IP_eth1}
          netmask ${ROUTER00_MASK_eth1}
          post-up ethtool -K eth1 tx on sg on tso on gso on gro on lro on || true
          post-up ethtool -C eth1 rx-usecs 0 || true

      auto eth2
      iface eth2 inet manual
          up ip link set \$IFACE up
          post-up ethtool -K eth2 tx on sg on tso on gso on gro on lro on || true
          post-up ethtool -C eth2 rx-usecs 0 || true

      auto eth2.20
      iface eth2.20 inet static
          address ${ROUTER00_IP_eth2_20}
          netmask 255.255.255.0

      auto eth2.30
      iface eth2.30 inet static
          address ${ROUTER00_IP_eth2_30}
          netmask 255.255.255.0

      auto eth3
      iface eth3 inet static
          address ${ROUTER00_IP_eth3}
          netmask 255.255.255.0
          post-up ethtool -K eth3 tx on sg on tso on gso on gro on lro on || true
          post-up ethtool -C eth3 rx-usecs 0 || true

  - path: /etc/dnsmasq.conf
    content: |
      interface=eth1
      interface=eth2.20
      interface=eth2.30
      interface=eth3
      bind-interfaces
      expand-hosts
      domain=${PRIMARY_DOMAIN}
      local=/${PRIMARY_DOMAIN}/
      server=8.8.8.8
      server=8.8.4.4
      server=/${DNS_REMOTE_DOMAIN}/${DNS_REMOTE_SERVER}
      dhcp-option=option:domain-search,${PRIMARY_DOMAIN},${DNS_REMOTE_DOMAIN}

      # LAN5
      dhcp-range=${DHCP_LAN5_START},${DHCP_LAN5_END},24h
      dhcp-option=interface:eth3,3,${ROUTER00_IP_eth3}
      dhcp-option=interface:eth3,6,${ROUTER00_IP_eth3}

      # LAN10
      dhcp-range=${DHCP_LAN10_START},${DHCP_LAN10_END},24h
      dhcp-option=interface:eth1,3,${ROUTER00_IP_eth1}
      dhcp-option=interface:eth1,6,${ROUTER00_IP_eth1}

      # VLAN20
      dhcp-range=set:vlan20,${DHCP_VLAN20_START},${DHCP_VLAN20_END},24h
      dhcp-option=tag:vlan20,3,${ROUTER00_IP_eth2_20}
      dhcp-option=tag:vlan20,6,${ROUTER00_IP_eth2_20}

      # VLAN30
      dhcp-range=set:vlan30,${DHCP_VLAN30_START},${DHCP_VLAN30_END},24h
      dhcp-option=tag:vlan30,3,${ROUTER00_IP_eth2_30}
      dhcp-option=tag:vlan30,6,${ROUTER00_IP_eth2_30}

      server=/${DNS_REMOTE_REVERSE}/${DNS_REMOTE_REVERSE_SERVER}
      conf-dir=/etc/dnsmasq.d/,*.conf

  - path: /etc/dnsmasq.d/static-hosts.conf
    content: |
${DNS_STATIC}

  - path: /etc/dnsmasq.d/static-dhcp.conf
    content: |
${DHCP_STATIC_HOSTS}

  - path: /etc/sysctl.d/router.conf
    content: |
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.send_redirects=0

  - path: /etc/iptables/rules-save
    content: |
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      -A INPUT -i lo -j ACCEPT
      -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

      # DMZ (eth0): accept only from the specific bastion IPs and WireGuard subnet
      -A INPUT -i eth0 -s ${IPTABLES_ETH0_ACCEPT_1} -j ACCEPT
      -A INPUT -i eth0 -s ${IPTABLES_ETH0_ACCEPT_2} -j ACCEPT

      # LAN10 (eth1): infrastructure subnet -- full access (DHCP, DNS, SSH, ICMP)
      -A INPUT -i eth1 -j ACCEPT

      # Application subnets (eth2.20, eth2.30, eth3/LAN5): DHCP and DNS only.
      # These subnets must not reach the router management plane directly.
      -A INPUT -i eth2.20 -p udp --dport 67:68 -j ACCEPT
      -A INPUT -i eth2.20 -p udp --dport 53    -j ACCEPT
      -A INPUT -i eth2.20 -p tcp --dport 53    -j ACCEPT
      -A INPUT -i eth2.30 -p udp --dport 67:68 -j ACCEPT
      -A INPUT -i eth2.30 -p udp --dport 53    -j ACCEPT
      -A INPUT -i eth2.30 -p tcp --dport 53    -j ACCEPT
      -A INPUT -i eth3    -p udp --dport 67:68 -j ACCEPT
      -A INPUT -i eth3    -p udp --dport 53    -j ACCEPT
      -A INPUT -i eth3    -p tcp --dport 53    -j ACCEPT

      -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

      # From DMZ (bastion / WireGuard tunnel): to all local subnets
      -A FORWARD -i eth0 -o eth1    -j ACCEPT
      -A FORWARD -i eth0 -o eth2.20 -j ACCEPT
      -A FORWARD -i eth0 -o eth2.30 -j ACCEPT
      -A FORWARD -i eth0 -o eth3    -j ACCEPT

      # From LAN10 (infrastructure): to all subnets and tunnel
      -A FORWARD -i eth1 -o eth0    -j ACCEPT
      -A FORWARD -i eth1 -o eth2.20 -j ACCEPT
      -A FORWARD -i eth1 -o eth2.30 -j ACCEPT
      -A FORWARD -i eth1 -o eth3    -j ACCEPT

      # From application subnets: to tunnel and cross-subnet only.
      # Explicitly NOT forwarded to eth1 (LAN10 / infrastructure isolation).
      -A FORWARD -i eth2.20 -o eth0    -j ACCEPT
      -A FORWARD -i eth2.20 -o eth2.30 -j ACCEPT
      -A FORWARD -i eth2.20 -o eth3    -j ACCEPT

      -A FORWARD -i eth2.30 -o eth0    -j ACCEPT
      -A FORWARD -i eth2.30 -o eth2.20 -j ACCEPT
      -A FORWARD -i eth2.30 -o eth3    -j ACCEPT

      -A FORWARD -i eth3 -o eth0    -j ACCEPT
      -A FORWARD -i eth3 -o eth2.20 -j ACCEPT
      -A FORWARD -i eth3 -o eth2.30 -j ACCEPT

      COMMIT

  - path: /etc/motd
    content: |
      ================================================================================
        CORE ROUTER - SITE: ${SITE_NAME^^}
      ================================================================================
        Purpose: DHCP, DNS, and inter-VLAN routing

        QUICK SANITY CHECKS:
        --------------------
        1. Interfaces  : ip -4 a
        2. Gateway     : ping -c 3 ${ROUTER00_GW_eth0}
        3. DNS test    : sudo dnsmasq --test && nslookup google.com 127.0.0.1
        4. DHCP leases : cat /var/lib/misc/dnsmasq.leases
        5. Internet    : ping -c 3 1.1.1.1
        6. Services    : rc-status

        FIREWALL / ROUTING:
        -------------------
        ip route show
        sudo iptables -L -n -v
        tcpdump -n -i eth2 (tagged VLAN traffic)
      ================================================================================

runcmd:
  - rc-update add networking boot
  - rc-service networking restart
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf
  - apk add --no-cache sudo htop dnsmasq iptables iptables-openrc tcpdump ethtool acpid
  - ln -sf /sbin/iptables-legacy         /sbin/iptables
  - ln -sf /sbin/iptables-legacy-restore /sbin/iptables-restore
  - ln -sf /sbin/iptables-legacy-save    /sbin/iptables-save
  - rc-update add iptables default
  - rc-update add dnsmasq  default
  - rc-update add acpid    default
  - sysctl -p /etc/sysctl.d/router.conf

  # router00 uses static networking -- dhcpcd (DHCP client) is not needed.
  # Disabling it prevents it from overwriting /etc/resolv.conf.
  # dnsmasq (DHCP+DNS server for clients) is unaffected.
  - rc-update del dhcpcd default 2>/dev/null || true
  - rc-service dhcpcd stop   2>/dev/null || true
  - apk del dhcpcd 2>/dev/null || true
  - printf "nameserver 127.0.0.1\nsearch ${PRIMARY_DOMAIN} ${SECONDARY_DOMAIN}\n" > /etc/resolv.conf

  # Disable IPv6: update-extlinux disables at kernel level
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

sudo virsh destroy  ${ROUTER00_VM_NAME} 2>/dev/null || true
sudo virsh undefine ${ROUTER00_VM_NAME} --remove-all-storage 2>/dev/null || true

sudo cloud-localds /var/lib/libvirt/images/${ROUTER00_VM_NAME}-cidata.iso \
    ${CIDATA}/user-data.yaml ${CIDATA}/meta-data

sudo cp /var/lib/libvirt/images/iso/${IMAGE_NAME} \
        /var/lib/libvirt/images/${ROUTER00_VM_NAME}.qcow2
sudo qemu-img resize /var/lib/libvirt/images/${ROUTER00_VM_NAME}.qcow2 6G

virt-install \
    --name ${ROUTER00_VM_NAME} \
    --memory 512 \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant alpinelinux3.21 \
    --disk path=/var/lib/libvirt/images/${ROUTER00_VM_NAME}.qcow2,format=qcow2 \
    --disk path=/var/lib/libvirt/images/${ROUTER00_VM_NAME}-cidata.iso,device=cdrom \
    --network network=${NET_eth0},mac=${MAC_eth0},model=virtio,driver.name=vhost,driver.queues=2 \
    --network network=${NET_eth1_portgroup},mac=${MAC_eth1},model=virtio,driver.name=vhost,driver.queues=2 \
    --network network=${NET_eth2_portgroup},mac=${MAC_eth2},model=virtio,driver.name=vhost,driver.queues=2 \
    --network network=${NET_eth3_portgroup},mac=${MAC_eth3},model=virtio,driver.name=vhost,driver.queues=2 \
    --graphics none \
    --import \
    --noautoconsole \
    --memorybacking nosharepages=yes,locked=yes \
    --cputune vcpupin0.vcpu=0,vcpupin0.cpuset=4,vcpupin1.vcpu=1,vcpupin1.cpuset=5,shares=4096 \
    --autostart

rm -rf ${CIDATA}

# Point server00 DNS at router00 now that it is running.
# Makes the host resolve lab hostnames from this point forward.
# The file is made immutable to prevent resolvconf from overwriting it.
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf
cat << EOF | sudo tee /etc/resolv.conf
# Managed by 09-create-router00.sh -- immutable (chattr +i)
# To edit: sudo chattr -i /etc/resolv.conf
nameserver ${ROUTER00_IP_eth1}
nameserver 8.8.8.8
nameserver 8.8.4.4
search ${PRIMARY_DOMAIN} ${SECONDARY_DOMAIN}
EOF
sudo systemctl disable --now resolvconf 2>/dev/null || true
sudo chattr +i /etc/resolv.conf

echo ""
echo "==> ${ROUTER00_VM_NAME} created -- cloud-init reboot in ~90s"
echo "    virsh console ${ROUTER00_VM_NAME}"
echo ""
echo "    Verify after reboot:"
echo "    ip a && ip r"
echo "    sudo dnsmasq --test"
echo "    nslookup ${ROUTER00_HOSTNAME}.${PRIMARY_DOMAIN}"
echo "    cat /var/lib/misc/dnsmasq.leases"
echo "    sudo iptables -L -n -v"
