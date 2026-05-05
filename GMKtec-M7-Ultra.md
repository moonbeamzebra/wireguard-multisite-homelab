# GMKtec M7 Ultra -- Hardware Reference

**Model:** GMKtec Mini PC M7 Ultra
**CPU:** AMD Ryzen 7 PRO 6850U (8C/16T, up to 4.70 GHz) -- also sold as M6 Ultra with Ryzen 7640HS
**GPU:** AMD Radeon 680M (integrated, RDNA 2)
**RAM:** 32 GB DDR5
**Storage:** 1 TB NVMe SSD (nvme0n1, ~953.9 GB usable)
**Network:** 2x Intel I226-V 2.5 GbE (enp1s0 right, eno1/enp2s0 left)
**Connectivity:** Wi-Fi 6E, Bluetooth 5.2, USB4, HDMI 2.1, DisplayPort

This document covers BIOS configuration, hardware-specific Linux notes, and
validation commands for both sites (site A and site B).

---

## Interface identification

```
enp1s0           RJ45 right   br-ext10   LAN10 / default route / Google Nest
eno1 (enp2s0)    RJ45 left    br-isp     WAN / ISP modem
wlp3s0           Wi-Fi        (preseed)  Bootstrap only -- removed in prod
```

The USB Ethernet dongle (UGREEN or equivalent) attaches as an `enx...`
interface and maps to `br-ext5` (LAN5 / server room).

---

## BIOS configuration

Access BIOS: press `Del` or `F2` at power-on.
Recommended prompt timeout: 5 seconds (helps wireless keyboard dongles initialize).

### Main tab

| Setting           | Target value | Notes                                        |
|-------------------|--------------|----------------------------------------------|
| Power Mode Select | Performance  | Avoids thermal throttling under KVM load     |
| System Date/Time  | Current      | Required for valid SSL/TLS and SSH           |

### Advanced tab

| Setting       | Target value | Notes                                              |
|---------------|--------------|----------------------------------------------------|
| Wake On LAN   | Enabled      | Remote power-on                                    |
| Auto Power On | Power On     | Auto-restart after power failure -- critical       |
| USB Boot      | Enabled      | Required for Debian install USB                    |

### Advanced > CPU Configuration

| Setting    | Target value | Notes                              |
|------------|--------------|------------------------------------|
| PSS Support | Enabled     | OS power management                |
| NX Mode     | Enabled     | Memory execution protection        |
| SVM Mode    | Enabled     | AMD-V -- required for KVM          |
| AMD SMT     | Enabled     | Enables all 16 logical threads     |

### Advanced > GFX Configuration

| Setting              | Site A | Site B | Notes                            |
|----------------------|--------|--------|----------------------------------|
| UMA Frame Buffer Size | 1G    | 2G     | Site B: larger for Jellyfin GPU  |

### Advanced > AMD CBS > NBIO Common Options

| Setting        | Target value | Notes                                          |
|----------------|--------------|------------------------------------------------|
| IOMMU          | Enabled      | Hardware isolation, PCI passthrough            |
| PCIe ARI Support | Auto       | Leave default                                  |
| PSPP Policy    | Balanced     | Prevents PCIe frequency drops under load       |

### Security tab

| Setting      | Target value | Notes                                            |
|--------------|--------------|--------------------------------------------------|
| Secure Boot  | Disabled     | Required for custom Linux kernels and DKMS       |

### Boot tab

| Setting              | Target value  | Notes                                      |
|----------------------|---------------|--------------------------------------------|
| Setup Prompt Timeout | 5             | Extra time for wireless keyboard dongle    |
| Boot Option 1        | USB Device    | Priority for Debian install                |
| Boot Option 2        | NVMe          | Becomes Debian/GRUB after install          |
| Quiet Boot           | Disabled      | Shows POST messages -- useful for debug    |

Save and exit: **Save Changes and Reset**.

---

## Kernel boot parameters (preseed)

Added to GRUB command line in the preseed template:

```
quiet amd_iommu=on iommu=pt ipv6.disable=1 pcie_aspm=off
```

- `amd_iommu=on iommu=pt` -- enables IOMMU passthrough mode for KVM
- `ipv6.disable=1` -- disables IPv6 at kernel level
- `pcie_aspm=off` -- disables PCIe Active State Power Management,
  prevents micro-latency spikes on the 2.5 GbE NICs

---

## Debian install answers (manual or preseed reference)

```
Language:          English
Country:           Canada
Keymap:            American English
Network:           Wi-Fi (bootstrap) or RJ45 (if available)
Hostname:          m-server00 (site A) / c-server00 (site B)
Domain:            (none -- set by preseed variables)
Root password:     (from secrets-A.env / secrets-B.env)
User:              lab
Timezone:          Eastern
Partition:         Entire disk, all files in one partition
Disk:              /dev/nvme0n1
Mirror:            Canada -- deb.debian.org
Proxy:             (none)
Survey:            No
Software:          SSH server, standard system utilities
```

---

## Linux validation after install

Run these after the first boot to confirm hardware is configured correctly.

### Virtualization and IOMMU

```bash
# Confirm AMD-V is enabled
lscpu | grep Virtualization

# Confirm IOMMU is active
dmesg | grep -i iommu

# Full hardware inventory
sudo lshw -c network -c storage -c disk
```

### Network interfaces

```bash
ip a
# Expect: enp1s0 (right RJ45), eno1/enp2s0 (left RJ45), wlp3s0 (Wi-Fi)

# Confirm 2.5 GbE driver on both NICs
ethtool -i enp1s0
ethtool -i eno1
# Expect: driver: igc (Intel I226-V)
```

### PCIe and NVMe

```bash
lspci -k       # PCI devices and their drivers
lspci -vv | grep ASPM   # Confirm ASPM is disabled: L0s- L1-
```

### Thermal

```bash
# Requires: sudo apt install lm-sensors && sudo sensors-detect
sensors | grep Tctl
```

### KVM virtual machine NIC offload validation

Run inside the Alpine bastion or router00 VMs to confirm vHost-Net is working:

```bash
# Expect: Combined: 2
ethtool -l eth0 | grep -i combined

# Expect: tcp-segmentation-offload: on, generic-segmentation-offload: on, etc.
ethtool -k eth0 | grep -E '(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|checksumming)'

# Expect: Adaptive RX: off, rx-usecs: 0
ethtool -c eth0
```

---

## WireGuard hardware acceleration

The Ryzen 6850U includes AES-NI and AVX2 instructions. WireGuard uses
ChaCha20-Poly1305 which benefits from SIMD acceleration on this CPU.

The bastion VM uses `--cpu host-passthrough` in virt-install to expose these
instructions to the guest kernel. This allows WireGuard to use the hardware
path rather than the software fallback.

To verify inside the bastion:
```bash
# Check that the CPU flags are visible inside the VM
grep -m1 flags /proc/cpuinfo | tr ' ' '\n' | grep -E 'aes|avx'
```

---

## GPU passthrough (site B -- Jellyfin)

Site B is configured with 2G UMA Frame Buffer for the Radeon 680M.
GPU passthrough to a Jellyfin VM for hardware transcoding is a planned
future step. The groundwork (IOMMU enabled, larger UMA buffer) is in place.

Validation commands (run after IOMMU is confirmed active):
```bash
# List IOMMU groups
find /sys/kernel/iommu_groups/ -type l | sort -V

# Confirm GPU is in its own group (required for clean passthrough)
lspci -nnk | grep -A3 VGA
```
