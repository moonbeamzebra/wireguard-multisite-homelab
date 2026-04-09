#!/bin/bash
# 08-create-router00.sh -- Deploy the router00 VM (Alpine -- DHCP/DNS/inter-VLAN routing)
#
# Usage:
#   source site-A.env && source secrets-A.env && bash 08-create-router00.sh
#   source site-B.env && source secrets-B.env && bash 08-create-router00.sh
#
# Required env vars (from site-*.env + secrets-*.env):
#   SITE_NAME, ROUTER00_VM_NAME, ROUTER00_HOSTNAME, PRIMARY_DOMAIN
#   ROUTER00_IP_eth0, ROUTER00_MASK_eth0, ROUTER00_GW_eth0
#   ROUTER00_IP_eth1, ROUTER00_MASK_eth1
#   ROUTER00_IP_eth2_20, ROUTER00_IP_eth2_30
#   DHCP_LAN10_START/END, DHCP_VLAN20_START/END, DHCP_VLAN30_START/END
#   DNS_REMOTE_DOMAIN, DNS_REMOTE_SERVER
#   DNS_REMOTE_REVERSE, DNS_REMOTE_REVERSE_SERVER
#   DNS_STATIC
#   IPTABLES_ETH0_ACCEPT_1, IPTABLES_ETH0_ACCEPT_2
#   NET_eth0, NET_eth1_portgroup, NET_eth2_portgroup
#   LAB_SSH_PUBKEY, LAB_PASSWORD, ROOT_PASSWORD

set -euo pipefail

# -- Validate required variables -----------------------------------------------
REQUIRED_VARS="SITE_NAME ROUTER00_VM_NAME ROUTER00_HOSTNAME PRIMARY_DOMAIN
               ROUTER00_IP_eth0 ROUTER00_MASK_eth0 ROUTER00_GW_eth0
               ROUTER00_IP_eth1 ROUTER00_MASK_eth1
               ROUTER00_IP_eth2_20 ROUTER00_IP_eth2_30
               DHCP_LAN10_START DHCP_LAN10_END
               DHCP_VLAN20_START DHCP_VLAN20_END
               DHCP_VLAN30_START DHCP_VLAN30_END
               DNS_REMOTE_DOMAIN DNS_REMOTE_SERVER
               DNS_REMOTE_REVERSE DNS_REMOTE_REVERSE_SERVER
               DNS_STATIC
               IPTABLES_ETH0_ACCEPT_1 IPTABLES_ETH0_ACCEPT_2
               NET_eth0 NET_eth1_portgroup NET_eth2_portgroup
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
IMAGE_NAME=nocloud_alpine-3.23.3-x86_64-bios-cloudinit-r0--updated.qcow2

MAC_eth0=$(echo "${ROUTER00_IP_eth0}"    | awk -F. '{printf "52:54:%02x:%02x:%02x:%02x\n", $1, $2, $3, $4}')
MAC_eth1=$(echo "${ROUTER00_IP_eth1}"    | awk -F. '{printf "52:54:%02x:%02x:%02x:%02x\n", $1, $2, $3, $4}')
MAC_eth2=$(echo "${ROUTER00_IP_eth2_20}" | awk -F. '{printf "52:54:%02x:%02x:%02x:%02x\n", $1, $2, $3, $4}')

echo "==> Site       : ${SITE_NAME}"
echo "==> VM         : ${ROUTER00_VM_NAME}"
echo "==> eth0 DMZ   : ${ROUTER00_IP_eth0}  GW=${ROUTER00_GW_eth0}  MAC=${MAC_eth0}"
echo "==> eth1 LAN10 : ${ROUTER00_IP_eth1}  MAC=${MAC_eth1}"
echo "==> eth2 trunk : VLAN20=${ROUTER00_IP_eth2_20}  VLAN30=${ROUTER00_IP_eth2_30}  MAC=${MAC_eth2}"
echo "==> DNS remote : ${DNS_REMOTE_DOMAIN} -> ${DNS_REMOTE_SERVER}"

CIDATA=/tmp/${ROUTER00_VM_NAME}-cidata
mkdir -p ${CIDATA}

cat > ${CIDATA}/meta-data << EOF
instance-id: ${ROUTER00_VM_NAME}
local-hostname: ${ROUTER00_VM_NAME}
EOF

# -- cloud-init user-data -- part a: header through dnsmasq conf-dir ------------
# resolv_conf points to 8.8.8.8/4.4.4.4 so cloud-init can install/upgrade
# packages; switches to 127.0.0.1 at end of runcmd once dnsmasq is running.
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
          address ${ROUTER00_IP_eth0}
          netmask ${ROUTER00_MASK_eth0}
          gateway ${ROUTER00_GW_eth0}

      auto eth1
      iface eth1 inet static
          address ${ROUTER00_IP_eth1}
          netmask ${ROUTER00_MASK_eth1}

      auto eth2
      iface eth2 inet manual
          up ip link set \$IFACE up

      auto eth2.20
      iface eth2.20 inet static
          address ${ROUTER00_IP_eth2_20}
          netmask 255.255.255.0

      auto eth2.30
      iface eth2.30 inet static
          address ${ROUTER00_IP_eth2_30}
          netmask 255.255.255.0

  - path: /etc/dnsmasq.conf
    content: |
      interface=eth1
      interface=eth2.20
      interface=eth2.30
      bind-interfaces
      expand-hosts
      domain=${PRIMARY_DOMAIN}
      local=/${PRIMARY_DOMAIN}/
      server=8.8.8.8
      server=8.8.4.4
      server=/${DNS_REMOTE_DOMAIN}/${DNS_REMOTE_SERVER}

      dhcp-option=option:domain-search,${PRIMARY_DOMAIN},${DNS_REMOTE_DOMAIN}

      dhcp-range=${DHCP_LAN10_START},${DHCP_LAN10_END},24h
      dhcp-option=3,${ROUTER00_IP_eth1}
      dhcp-option=6,${ROUTER00_IP_eth1}

      dhcp-range=set:vlan20,${DHCP_VLAN20_START},${DHCP_VLAN20_END},24h
      dhcp-option=tag:vlan20,3,${ROUTER00_IP_eth2_20}
      dhcp-option=tag:vlan20,6,${ROUTER00_IP_eth2_20}

      dhcp-range=set:vlan30,${DHCP_VLAN30_START},${DHCP_VLAN30_END},24h
      dhcp-option=tag:vlan30,3,${ROUTER00_IP_eth2_30}
      dhcp-option=tag:vlan30,6,${ROUTER00_IP_eth2_30}

      server=/${DNS_REMOTE_REVERSE}/${DNS_REMOTE_REVERSE_SERVER}

      conf-dir=/etc/dnsmasq.d/,*.conf

EOF

# -- cloud-init user-data -- part b: static DNS host records -------------------
# DNS_STATIC is defined in site-*.env with 6-space indent
# to align inside the YAML content: | block.
cat >> ${CIDATA}/user-data.yaml << EOF

  - path: /etc/dnsmasq.d/static-hosts.conf
    content: |
${DNS_STATIC}
EOF

# -- cloud-init user-data -- part c: sysctl, iptables, runcmd ------------------
cat >> ${CIDATA}/user-data.yaml << EOF

  - path: /etc/sysctl.d/router.conf
    content: |
      net.ipv4.ip_forward=1

  - path: /etc/iptables/rules-save
    content: |
      *nat
      :PREROUTING ACCEPT [0:0]
      :INPUT ACCEPT [0:0]
      :OUTPUT ACCEPT [0:0]
      :POSTROUTING ACCEPT [0:0]
      COMMIT

      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]

      -A INPUT -i lo -j ACCEPT
      -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      -A INPUT -i eth0 -s ${IPTABLES_ETH0_ACCEPT_1} -j ACCEPT
      -A INPUT -i eth0 -s ${IPTABLES_ETH0_ACCEPT_2} -j ACCEPT
      -A INPUT -i eth1    -j ACCEPT
      -A INPUT -i eth2.20 -j ACCEPT
      -A INPUT -i eth2.30 -j ACCEPT

      -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
      -A FORWARD -i eth0    -o eth1    -j ACCEPT
      -A FORWARD -i eth0    -o eth2.20 -j ACCEPT
      -A FORWARD -i eth0    -o eth2.30 -j ACCEPT
      -A FORWARD -i eth1    -o eth0    -j ACCEPT
      -A FORWARD -i eth2.20 -o eth0    -j ACCEPT
      -A FORWARD -i eth2.30 -o eth0    -j ACCEPT
      -A FORWARD -i eth1    -o eth2.20 -j ACCEPT
      -A FORWARD -i eth1    -o eth2.30 -j ACCEPT
      -A FORWARD -i eth2.20 -o eth1    -j ACCEPT
      -A FORWARD -i eth2.30 -o eth1    -j ACCEPT
      -A FORWARD -i eth2.20 -o eth2.30 -j ACCEPT
      -A FORWARD -i eth2.30 -o eth2.20 -j ACCEPT
      COMMIT

runcmd:
  - rc-update add networking boot
  - rc-service networking restart
  - echo "nameserver 8.8.8.8" > /etc/resolv.conf
  - apk add --no-cache sudo htop dnsmasq iptables iptables-openrc tcpdump
  - mkdir -p /etc/dnsmasq.d

  # Fix iptables: force legacy (virtualised kernel lacks nf_tables)
  - ln -sf /sbin/iptables-legacy         /sbin/iptables
  - ln -sf /sbin/iptables-legacy-restore /sbin/iptables-restore
  - ln -sf /sbin/iptables-legacy-save    /sbin/iptables-save
  - rc-update add iptables default
  - rc-update add dnsmasq default
  - sysctl -p /etc/sysctl.d/router.conf
  - /etc/init.d/iptables start
  - rc-service networking restart
  - rc-service dnsmasq restart
  # Switch resolver to dnsmasq once it's running
  - echo "nameserver 127.0.0.1" > /etc/resolv.conf
  - touch /etc/cloud/cloud-init.disabled
  - rc-update del cloud-init default 2>/dev/null || true
  - rc-update del cloud-config default 2>/dev/null || true
  - rc-update del cloud-final default 2>/dev/null || true
  - reboot

EOF

sudo virsh destroy ${ROUTER00_VM_NAME} 2>/dev/null || true
sudo virsh undefine ${ROUTER00_VM_NAME} --remove-all-storage 2>/dev/null || true

sudo cloud-localds /var/lib/libvirt/images/${ROUTER00_VM_NAME}-cidata.iso \
    ${CIDATA}/user-data.yaml \
    ${CIDATA}/meta-data

sudo cp /var/lib/libvirt/images/iso/${IMAGE_NAME} \
        /var/lib/libvirt/images/${ROUTER00_VM_NAME}.qcow2
sudo qemu-img resize /var/lib/libvirt/images/${ROUTER00_VM_NAME}.qcow2 6G

virt-install \
    --name ${ROUTER00_VM_NAME} \
    --memory 512 \
    --vcpus 1 \
    --os-variant alpinelinux3.17 \
    --disk path=/var/lib/libvirt/images/${ROUTER00_VM_NAME}.qcow2,format=qcow2 \
    --disk path=/var/lib/libvirt/images/${ROUTER00_VM_NAME}-cidata.iso,device=cdrom \
    --network network=${NET_eth0},mac=${MAC_eth0} \
    --network network=${NET_eth1_portgroup},mac=${MAC_eth1} \
    --network network=${NET_eth2_portgroup},mac=${MAC_eth2} \
    --graphics none \
    --import \
    --noautoconsole

virsh autostart ${ROUTER00_VM_NAME}

echo ""
echo "==> VM ${ROUTER00_VM_NAME} created"
echo "    Boot 1: update/upgrade/reboot (~90s)"
echo "    Boot 2: dnsmasq + iptables operational"
echo ""
echo "==> Monitor with:"
echo "    virsh console ${ROUTER00_VM_NAME}"
echo ""
echo "==> Checks after boot 2:"
echo ""
echo "# Networking"
echo "ip a && ip r"
echo ""
echo "# Connectivity"
echo "ping ${ROUTER00_GW_eth0}    # bastion DMZ"
echo "ping 8.8.8.8 && ping google.com"
echo ""
echo "# DNS"
echo "sudo dnsmasq --test                          # validate config syntax"
echo "nslookup ${ROUTER00_HOSTNAME}.${PRIMARY_DOMAIN}  # local resolution"
echo ""
echo "# DHCP leases"
echo "cat /var/lib/misc/dnsmasq.leases"
echo ""
echo "# iptables"
echo "sudo iptables -L -n -v"
echo "sudo iptables -t nat -L -n -v"
