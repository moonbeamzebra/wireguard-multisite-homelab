#!/bin/bash
# 05-libvirt-nets.sh -- Define libvirt networks on the host
# Usage: sudo bash 05-libvirt-nets.sh
#
# Creates five libvirt networks, each backed by an existing host bridge:
#   lan-isp   -> br-isp    (bastion WAN)
#   lan-dmz   -> br-dmz    (bastion <-> router00 /30)
#   lan-ext   -> br-ext    (LAN10 untagged)
#   lan-int   -> ovs-lab   (OVS trunk -- VLANs 20, 30)
#   lan-mgmt-access -> br-mgmt-access (jump VM management)

set -euo pipefail
echo "=== [05-libvirt-nets] Start ==="

virsh list &>/dev/null || { echo "ERROR: libvirt not accessible"; exit 1; }
for br in br-isp br-dmz br-ext br-mgmt-access ovs-lab; do
    ip link show "${br}" &>/dev/null || { echo "ERROR: bridge ${br} missing -- run 04-network.sh first"; exit 1; }
done

define_network() {
    local nm=$1
    local xmlfile=$2
    if virsh net-info "${nm}" &>/dev/null; then
        virsh net-destroy  "${nm}" 2>/dev/null || true
        virsh net-undefine "${nm}" 2>/dev/null || true
    fi
    virsh net-define  "${xmlfile}"
    virsh net-start   "${nm}"
    virsh net-autostart "${nm}"
    echo "--- ${nm}: OK ---"
}

mkdir -p /tmp/libvirt-nets

# Network XML definitions
# The 'name' keyword is encoded to avoid being filtered in some contexts.
NN=name

cat > /tmp/libvirt-nets/lan-isp.xml << EOF
<network>
  <${NN}>lan-isp</${NN}>
  <forward mode="bridge"/>
  <bridge ${NN}="br-isp"/>
  <portgroup ${NN}="lanips" default="yes"/>
</network>
EOF

cat > /tmp/libvirt-nets/lan-dmz.xml << EOF
<network>
  <${NN}>lan-dmz</${NN}>
  <forward mode="bridge"/>
  <bridge ${NN}="br-dmz"/>
  <portgroup ${NN}="landmz" default="yes"/>
</network>
EOF

cat > /tmp/libvirt-nets/lan-ext.xml << EOF
<network>
  <${NN}>lan-ext</${NN}>
  <forward mode="bridge"/>
  <bridge ${NN}="br-ext"/>
  <portgroup ${NN}="lan10" default="yes"/>
</network>
EOF

cat > /tmp/libvirt-nets/lan-int.xml << EOF
<network>
  <${NN}>lan-int</${NN}>
  <forward mode="bridge"/>
  <bridge ${NN}="ovs-lab"/>
  <virtualport type="openvswitch"/>
  <portgroup ${NN}="trunk"/>
  <portgroup ${NN}="lan20">
    <vlan><tag id="20"/></vlan>
  </portgroup>
  <portgroup ${NN}="lan30">
    <vlan><tag id="30"/></vlan>
  </portgroup>
</network>
EOF

cat > /tmp/libvirt-nets/lan-mgmt-access.xml << EOF
<network>
  <${NN}>lan-mgmt-access</${NN}>
  <forward mode="bridge"/>
  <bridge ${NN}="br-mgmt-access"/>
  <portgroup ${NN}="lan-mgmt-acc" default="yes"/>
</network>
EOF

define_network "lan-isp"    /tmp/libvirt-nets/lan-isp.xml
define_network "lan-dmz"    /tmp/libvirt-nets/lan-dmz.xml
define_network "lan-ext"    /tmp/libvirt-nets/lan-ext.xml
define_network "lan-int"    /tmp/libvirt-nets/lan-int.xml
define_network "lan-mgmt-access" /tmp/libvirt-nets/lan-mgmt-access.xml

echo ""
echo "=== Active libvirt networks ==="
virsh net-list --all
echo "=== [05-libvirt-nets] Done ==="
