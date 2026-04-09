#!/bin/bash
# 04-network.sh -- Host network configuration (OVS + netplan bridges)
#
# Usage:
#   source site-A.env && source secrets-A.env && sudo -E bash 04-network.sh
#   source site-B.env && source secrets-B.env && sudo -E bash 04-network.sh
#
# Network layout -- the host is a dumb bridge/hypervisor, not a router:
#   IF_LAN        -> br-ext         IP_BR_EXT  (LAN / default route -- only IP on host)
#   IF_ISP        -> br-isp         no IP      (WAN passthrough to bastion VM only)
#   IF_MGMT_ACCESS -> br-mgmt-access no IP      (Mac management access for jump VM)
#   br-dmz                          no IP      (virtual bastion<->router00 /30 segment)
#   ovs-lab                         no IP      (OVS trunk -- VLANs 20, 30)
#
# ip_forward is NOT enabled on the host -- only bastion and router00 KVMs need it.

set -euo pipefail

# -- Validate required variables -----------------------------------------------
for VAR in SITE_NAME IF_LAN IF_ISP IF_MGMT_ACCESS IP_BR_EXT GW_BR_EXT PRIMARY_DOMAIN SECONDARY_DOMAIN; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: missing variable: ${VAR}"
        echo "Usage: source site-A.env && source secrets-A.env && sudo -E bash 04-network.sh"
        exit 1
    fi
done

echo "=== [04-network] Start -- site: ${SITE_NAME} ==="
echo "    IF_LAN         = ${IF_LAN} -> br-ext          ${IP_BR_EXT}"
echo "    IF_ISP         = ${IF_ISP} -> br-isp           (no IP -- passthrough)"
echo "    IF_MGMT_ACCESS = ${IF_MGMT_ACCESS} -> br-mgmt-access  (no IP)"
echo "    Gateway        = ${GW_BR_EXT}"

# -- Check prerequisites -------------------------------------------------------
for pkg in netplan.io openvswitch-switch; do
    dpkg -l "${pkg}" &>/dev/null || { echo "ERROR: ${pkg} missing -- run 03-packages.sh first"; exit 1; }
done

# -- OVS: ovs-lab (VLAN trunk -- no physical uplink) ---------------------------
echo "--- Creating ovs-lab ---"
ovs-vsctl --may-exist add-br ovs-lab
ovs-vsctl set port ovs-lab vlan_mode=trunk trunks=[]
ip link set ovs-lab up

# -- Systemd service to restore ovs-lab after reboot --------------------------
echo "--- Persisting ovs-lab via systemd ---"
cat > /usr/local/bin/ovs-setup-${SITE_NAME}.sh << EOF
#!/bin/bash
set -e
ovs-vsctl --may-exist add-br ovs-lab
ovs-vsctl set port ovs-lab vlan_mode=trunk trunks=[]
ip link set ovs-lab up
EOF
chmod +x /usr/local/bin/ovs-setup-${SITE_NAME}.sh

cat > /etc/systemd/system/ovs-setup-${SITE_NAME}.service << EOF
[Unit]
Description=OVS Setup - ${SITE_NAME} (ovs-lab)
After=ovsdb-server.service ovs-vswitchd.service network.target
Wants=ovsdb-server.service ovs-vswitchd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ovs-setup-${SITE_NAME}.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ovs-setup-${SITE_NAME}.service
systemctl start  ovs-setup-${SITE_NAME}.service

# -- Disable ifupdown (conflicts with netplan) ---------------------------------
echo "--- Disabling ifupdown ---"
cat > /etc/network/interfaces << 'IFEOF'
# Managed by netplan -- do not edit
auto lo
iface lo inet loopback
IFEOF

systemctl stop networking 2>/dev/null || true
systemctl disable networking 2>/dev/null || true

# -- Netplan configuration -----------------------------------------------------
echo "--- Writing netplan config ---"
rm -f /etc/netplan/01-netcfg.yaml
rm -f /etc/netplan/01-network-manager-all.yaml

cat > /etc/netplan/10-lab-${SITE_NAME}.yaml << EOF
network:
  version: 2
  renderer: networkd

  ethernets:
    ${IF_LAN}:
      dhcp4: no
    ${IF_ISP}:
      dhcp4: no
    ${IF_MGMT_ACCESS}:
      dhcp4: no
      optional: true

  bridges:
    br-ext:
      interfaces: [${IF_LAN}]
      dhcp4: no
      addresses: [${IP_BR_EXT}]
      routes:
        - to: default
          via: ${GW_BR_EXT}
      nameservers:
        addresses: [${GW_BR_EXT}, 8.8.8.8]
        search: [${PRIMARY_DOMAIN}, ${SECONDARY_DOMAIN}]
      parameters:
        stp: false
        forward-delay: 0

    br-isp:
      interfaces: [${IF_ISP}]
      dhcp4: no
      parameters:
        stp: false
        forward-delay: 0

    br-dmz:
      dhcp4: no
      parameters:
        stp: false
        forward-delay: 0

    br-mgmt-access:
      interfaces: [${IF_MGMT_ACCESS}]
      dhcp4: no
      parameters:
        stp: false
        forward-delay: 0

EOF

chmod 600 /etc/netplan/10-lab-${SITE_NAME}.yaml

echo "--- Validating netplan ---"
netplan generate && echo "netplan generate: OK" || { echo "ERROR: netplan generate failed"; exit 1; }

# -- OVS state -----------------------------------------------------------------
echo "--- OVS state ---"
ovs-vsctl show

echo ""
echo "=== [04-network] Ready ==="
echo ""
IP_ONLY=$(echo "${IP_BR_EXT}" | cut -d/ -f1)
echo "NOTE: The host already has a static IP (${IP_ONLY}) set since preseed."
echo "      'netplan apply' reconfigures bridges but the IP itself does not change."
echo "      The current SSH session should survive if you are connected on ${IP_ONLY}."
echo ""
echo "Run when ready:"
echo "  sudo netplan apply"
echo ""
echo "Reconnect if needed: ssh lab@${IP_ONLY}"
echo ""
echo "Then verify:"
echo "  ip a                   # br-ext should show ${IP_BR_EXT}"
echo "  ip r                   # default route via ${GW_BR_EXT}"
echo "  sudo ovs-vsctl show    # ovs-lab should appear"
echo ""
echo "NOTE: ping ${GW_BR_EXT} and ping 8.8.8.8 will fail until router00 is deployed."
echo "      Internet during this phase goes via jmp00 (${PRESEED_GW:-10.x.10.254})."
