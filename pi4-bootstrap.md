# Pi 4 Bootstrap Guide

This document describes how to install Alpine Linux on a Raspberry Pi 4 and
prepare it to run the bastion + router00 setup via `10-bastion-router00-on-pi4.sh`.

---

## Hardware requirements

- Raspberry Pi 4 (any RAM variant)
- MicroSD card (8 GB or more)
- USB Ethernet dongle (the WAN interface -- toward your ISP modem)
- Screen and USB keyboard (needed only for the initial Alpine install)
- Internet access during install (via the USB dongle or the integrated RJ45)

### Interface assignment

| Physical port       | Variable  | Role                                     |
|---------------------|-----------|------------------------------------------|
| Integrated RJ45     | `eth0`    | LAN -- toward the home network / Google Nest |
| USB Ethernet dongle | `eth1`    | WAN -- toward the ISP modem              |

---

## Step 1 -- Prepare the SD card (on macOS)

1. Open **Disk Utility**.
2. Select your SD card and click **Erase**:
   - Name: `ALPINE`
   - Format: **MS-DOS (FAT)**
   - Scheme: **Master Boot Record (MBR)**

3. Download the Alpine Raspberry Pi image from
   [alpinelinux.org/downloads](https://alpinelinux.org/downloads) --
   choose the **Raspberry Pi** section, architecture **aarch64**.
   Example: `alpine-rpi-3.23.3-aarch64.tar.gz`

4. Extract the archive **directly to the root of the SD card**
   (not into a subfolder):
   ```
   tar xzf alpine-rpi-3.23.3-aarch64.tar.gz -C /Volumes/ALPINE/
   ```

---

## Step 2 -- First boot and Alpine setup

Insert the SD card, connect screen and keyboard, power on.

Login: `root` (no password).

Run the Alpine setup wizard:

```
setup-alpine
```

Answer the prompts as follows:

| Prompt                  | Answer                        |
|-------------------------|-------------------------------|
| Keyboard layout         | `us`                          |
| Keyboard variant        | `us`                          |
| Hostname                | `c-server00` (or your choice) |
| Network interface       | `eth0`                        |
| eth0 config             | `dhcp`                        |
| eth1 config             | `dhcp`                        |
| Manual network config   | `n`                           |
| Root password           | (your choice)                 |
| Timezone                | `Canada/Eastern` (or your TZ) |
| Proxy                   | `none`                        |
| NTP client              | `chrony`                      |
| APK mirror              | `1` (or pick a close one)     |
| Create user             | login `lab`, full name `lab`  |
| Lab user password       | (your choice)                 |
| SSH key for lab         | `none`                        |
| SSH server              | `openssh`                     |
| Boot media              | `mmcblk0p1` -- answer `y`     |
| Disk to use             | `mmcblk0`                     |
| How to use disk         | `sys`                         |
| Erase disk              | `y`                           |

The installer writes Alpine to the SD card and reboots.

---

## Step 3 -- Copy the lab files to the Pi

After the Pi reboots, log in as `root`.

From your workstation, copy the scripts and config files to the Pi:

```sh
scp site-B-pi4-atCottage.env \
    secrets-B-pi4.env \
    secrets-pi4-wg0-core.conf \
    site-B-pi4-simulationAtHome.env \
    10-bastion-router00-on-pi4.sh \
    root@<pi4-ip>:/root/
```

The secret files must be filled in from their templates before copying:

```sh
cp secrets-B-pi4.env.template secrets-B-pi4.env
# edit secrets-B-pi4.env -- fill in WG keys, endpoint, SSH public key

cp secrets-pi4-wg0-core.conf.template secrets-pi4-wg0-core.conf
# edit secrets-pi4-wg0-core.conf -- fill in WG private key, peer public key, endpoint
```

---

## Step 4 -- Run the setup script

On the Pi, as root:

```sh
cd /root
ash 10-bastion-router00-on-pi4.sh
```

The script:
- Installs packages (wireguard-tools, dnsmasq, iptables, etc.)
- Writes `/etc/local.d/network.start` (namespace + WireGuard + iptables setup)
- Writes `/root/lab/mgmt-access.sh` (dual SSHD for management access)
- Writes `/etc/dnsmasq-cottage.conf`
- Sets `/etc/network/interfaces` to manual on both interfaces
- Reboots when done

---

## Step 5 -- Verify after reboot

Log back in as root and run the test helper:

```sh
/root/lab/test.sh
```

Expected results:
- `ip netns list` shows `bastion` and `router00`
- `ping 8.8.8.8` from bastion namespace succeeds
- `wg show` shows a recent handshake with the site A bastion
- Ping to `10.0.0.1` (remote site A wg0) succeeds through the tunnel

---

## SSH access model

The Pi does not run Alpine's native sshd. Instead, `mgmt-access.sh` starts
two custom sshd instances at every boot:

```
Mac / workstation
    |
    | ssh -J lab@<pi4-lan-ip> lab@<fmp-d-ip>
    |
    v
Entry SSHD (inside router00 namespace, 10.1.10.1:22)
    |  ProxyJump only -- no TTY, no shell, AllowTcpForwarding yes
    v
Host SSHD (default namespace, fmp-d IP:22)
    |  Full shell access for 'lab' and 'root'
    v
Pi 4 default namespace (root / lab)
```

Once connected to the Pi, use these aliases:

```sh
bastion   # enter bastion namespace (root: ip netns exec bastion ash)
router    # enter router00 namespace
```

The `fmp` veth pair (fmp-d in default ns, fmp-u in router00 ns) is a
dedicated management path that does not interfere with production traffic.

---

## Emergency recovery

If the Pi becomes unreachable after a bad `network.start`:

1. Connect keyboard and screen to the Pi.
2. Log in as root.
3. Run:
   ```sh
   rm /etc/local.d/network.start
   rc-update add sshd default
   cp /root/lab/interfaces /etc/network/interfaces
   reboot
   ```
4. The Pi will come up with plain DHCP on both interfaces and Alpine's
   native sshd running. SSH in, fix the issue, and re-run the script.

---

## Choosing between atCottage and simulationAtHome

Two site-B env files are provided:

| File                              | Use case                                      |
|-----------------------------------|-----------------------------------------------|
| `site-B-pi4-atCottage.env`        | Pi physically at the cottage, on its own ISP  |
| `site-B-pi4-simulationAtHome.env` | Pi at home, simulating site B on your home LAN|

The script uses `site-B-pi4-atCottage.env` by default. To test at home
before deploying to the cottage, edit the script's copy step in section 3
to use the simulation env instead.
