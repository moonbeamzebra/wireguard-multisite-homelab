# CE Router Notes (OpenWRT -- ISP CPE simulation)

These routers are configured manually via the VMware console then SSH.
No scripts are needed -- CE routers are not present in a physical deployment.

Hostnames: h-ce (site home) and c-ce (site cottage).

---

## VM creation (run once on the Mac Intel)

```
curl -L -O https://downloads.openwrt.org/releases/23.05.3/targets/x86/64/openwrt-23.05.3-x86-64-generic-ext4-combined.img.gz
gunzip openwrt-23.05.3-x86-64-generic-ext4-combined.img.gz

qemu-img convert -f raw -O vmdk \
  openwrt-23.05.3-x86-64-generic-ext4-combined.img \
  openwrt.vmdk

cp openwrt.vmdk openwrt-h-ce.vmdk
cp openwrt.vmdk openwrt-c-ce.vmdk
```

Create each VM manually in VMware Fusion:
- File -> New -> Create custom VM
- OS: Linux / Other Linux 6.x kernel 64-bit
- Disk: Use existing -> site-specific copy of the VMDK
- RAM: 256 MB   CPU: 1
- Adapter 1 (LAN): vmnet3 (site home) / vmnet10 (site cottage)
- Adapter 2 (WAN): VMnet8 (NAT -- shared with Mac)

---

## Site home -- h-ce  (LAN 192.168.0.1 / WAN 192.168.16.100)

### Step 1 -- VMware console (single line)
```
passwd
# enter: labpassword

uci set network.lan.ipaddr='192.168.0.1' && uci commit network && /etc/init.d/network restart
```

### Step 2 -- SSH root@192.168.0.1
```
# Static WAN IP
uci set network.wan.proto='static'
uci set network.wan.ipaddr='192.168.16.100'
uci set network.wan.netmask='255.255.255.0'
uci set network.wan.gateway='192.168.16.2'
uci set network.wan.dns='8.8.8.8'
uci commit network
/etc/init.d/network restart

# Hostname
uci set system.@system[0].hostname='h-ce'
uci commit system
/etc/init.d/system reload

# WireGuard port forward UDP 51820 -> h-bastion
uci add firewall redirect
uci set firewall.@redirect[-1].name='wireguard'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].proto='udp'
uci set firewall.@redirect[-1].src_dport='51820'
uci set firewall.@redirect[-1].dest_ip='192.168.0.10'
uci set firewall.@redirect[-1].dest_port='51820'
uci set firewall.@redirect[-1].target='DNAT'
uci commit firewall
/etc/init.d/firewall restart
```

---

## Site cottage -- c-ce  (LAN 192.168.1.1 / WAN 192.168.16.101)

### Step 1 -- VMware console (single line)
```
passwd
# enter: labpassword

uci set network.lan.ipaddr='192.168.1.1' && uci commit network && /etc/init.d/network restart
```

### Step 2 -- SSH root@192.168.1.1
```
# Static WAN IP
uci set network.wan.proto='static'
uci set network.wan.ipaddr='192.168.16.101'
uci set network.wan.netmask='255.255.255.0'
uci set network.wan.gateway='192.168.16.2'
uci set network.wan.dns='8.8.8.8'
uci commit network
/etc/init.d/network restart

# Hostname
uci set system.@system[0].hostname='c-ce'
uci commit system
/etc/init.d/system reload

# WireGuard port forward UDP 51820 -> c-bastion
uci add firewall redirect
uci set firewall.@redirect[-1].name='wireguard'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].proto='udp'
uci set firewall.@redirect[-1].src_dport='51820'
uci set firewall.@redirect[-1].dest_ip='192.168.1.10'
uci set firewall.@redirect[-1].dest_port='51820'
uci set firewall.@redirect[-1].target='DNAT'
uci commit firewall
/etc/init.d/firewall restart
```

---

## IP summary

| Site    | Hostname | LAN IP       | WAN IP          | WG forward target |
|---------|----------|--------------|-----------------|-------------------|
| home    | h-ce     | 192.168.0.1  | 192.168.16.100  | 192.168.0.10      |
| cottage | c-ce     | 192.168.1.1  | 192.168.16.101  | 192.168.1.10      |
