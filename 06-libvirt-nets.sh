#!/bin/bash
# 06-libvirt-nets.sh -- Define libvirt networks on the host
# Usage: sudo bash 06-libvirt-nets.sh
#
# Creates five libvirt networks, each backed by an existing host bridge:
#   lan-isp   -> br-isp    (bastion WAN)
#   lan-dmz   -> br-dmz    (bastion <-> router00 /30)
#   lan-ext10 -> br-ext10    (LAN10 untagged)
#   lan-int   -> ovs-lab   (OVS trunk -- VLANs 20, 30)

set -euo pipefail
echo "=== [06-libvirt-nets] Start ==="

virsh list &>/dev/null || { echo "ERROR: libvirt not accessible"; exit 1; }
for br in br-isp br-dmz br-ext10 ovs-lab; do
    ip link show "${br}" &>/dev/null || { echo "ERROR: bridge ${br} missing -- run 05-network.sh first"; exit 1; }
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
# The XML <name> tag is written via a variable to avoid being stripped
# by some text processing tools that interpret angle brackets. to avoid being filtered in some contexts.
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

cat > /tmp/libvirt-nets/lan-ext5.xml << EOF
<network>
  <${NN}>lan-ext5</${NN}>
  <forward mode="bridge"/>
  <bridge ${NN}="br-ext5"/>
  <portgroup ${NN}="lan5" default="yes"/>
</network>
EOF

cat > /tmp/libvirt-nets/lan-ext10.xml << EOF
<network>
  <${NN}>lan-ext10</${NN}>
  <forward mode="bridge"/>
  <bridge ${NN}="br-ext10"/>
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

define_network "lan-isp"    /tmp/libvirt-nets/lan-isp.xml
define_network "lan-dmz"    /tmp/libvirt-nets/lan-dmz.xml
define_network "lan-ext5"    /tmp/libvirt-nets/lan-ext5.xml
define_network "lan-ext10"    /tmp/libvirt-nets/lan-ext10.xml
define_network "lan-int"    /tmp/libvirt-nets/lan-int.xml

echo ""
echo "=== Active libvirt networks ==="
virsh net-list --all
echo "=== [06-libvirt-nets] Done ==="
