# NUT UPS Setup — Multi-Site Home Lab

## Overview

Each site has a CyberPower EC850LCD UPS with the server (GMKtec M7 Ultra) connected
directly via USB. NUT runs in standalone mode on server00 — no separate NUT server,
no Raspberry Pi, no Wake-on-LAN needed.

When power fails and battery drops to the configured threshold, server00 gracefully
shuts down all KVMs and LXC containers, then powers off. When power returns, the
UPS restores its output and server00 starts automatically via BIOS "Power On after
AC Loss" setting.

### Architecture

```
CyberPower EC850LCD
        │
        │ USB
        ▼
  server00 (GMKtec M7 Ultra)
  ┌─────────────────────────────────────────┐
  │  nut-driver@cyberpower  (reads UPS)     │
  │  nut-server             (upsd)          │
  │  nut-monitor            (upsmon)        │
  │                                         │
  │  On LOWBATT:                            │
  │    nut-shutdown.sh                      │
  │      → virsh shutdown all KVMs (parallel)│
  │      → virsh shutdown all LXC (parallel) │
  │      → log battery charge at poweroff   │
  │      → systemctl poweroff               │
  └─────────────────────────────────────────┘
        │
        │ AC power restored
        ▼
  UPS restores output → BIOS auto power-on → server00 boots
```

**Equipment per site:**

| Site | UPS | Server |
|---|---|---|
| A (maison) | CyberPower EC850LCD | m-server00 `10.0.10.2` |
| B (chalet) | CyberPower EC850LCD | c-server00 `10.1.10.2` |

---

## NUT Timing Reference

| Parameter | Value | Notes |
|---|---|---|
| Battery shutdown threshold | `NUT_BATTERY_WARN` % | Configurable in `site-X.env` |
| `FINALDELAY` | 120s | Time between shutdown command and poweroff |
| KVM graceful shutdown timeout | 60s | Per `nut-shutdown.sh` |
| LXC graceful shutdown timeout | 30s | Per `nut-shutdown.sh` |

---

## Configuration

### site-X.env additions

Add these to both `site-A.env` and `site-B.env`:

```bash
export NUT_UPS_NAME="cyberpower"
export NUT_USER="monuser"
export NUT_BATTERY_WARN=20     # shutdown at 20%; use -1 for firmware default
```

### site-X-secrets.env additions

```bash
export NUT_PASSWORD="<secret>"
```

### NUT_BATTERY_WARN values

| Value | Behavior |
|---|---|
| `-1` | Use firmware LOWBATT signal (CyberPower decides when to shutdown) |
| `1`–`99` | Shutdown when battery drops to this percentage (software threshold via `ignorelb`) |

> **Note:** With a CyberPower EC850LCD at ~63W load (~15% of 450W nominal), battery
> drains roughly 1% per 2 minutes. At 20%, you have ~40 minutes of runtime after
> the panne starts, with a safe margin before the UPS dies.

---

## Installation

### Step 1 — BIOS configuration

On the GMKtec M7 Ultra, set **before** running the script:

```
BIOS → Advanced → Power Management → Restore on AC Power Loss → Power On
```

This is what restarts server00 when power returns — no WOL needed.

### Step 2 — Run the setup script

```bash
source site-B.env && source site-B-secrets.env
sudo -E bash nut-server-setup-on-server00.sh
```

### Step 3 — Verify

```bash
# UPS detected and responding
upsc cyberpower@localhost ups.status     # expect: OL (On Line)
upsc cyberpower@localhost battery.charge # expect: 100
upsc cyberpower@localhost battery.charge.low  # expect: your NUT_BATTERY_WARN value

# Services running
systemctl status nut-driver@cyberpower
systemctl status nut-server
systemctl status nut-monitor

# Logs
journalctl -u nut-monitor -f
```

> **Important:** `battery.charge.low` must match `NUT_BATTERY_WARN`. If it shows
> the firmware default (usually 5 or 10) instead of your configured value, restart
> the driver:
> ```bash
> sudo systemctl restart nut-driver@cyberpower
> sleep 3 && sudo systemctl restart nut-server nut-monitor
> upsc cyberpower@localhost battery.charge.low
> ```

---

## Testing

### Prepare — Set Test Threshold

Edit `ups.conf` to use a high threshold (e.g. 98%) so shutdown triggers quickly:

```bash
sudo vi /etc/nut/ups.conf
# Set both lines:
#   override.battery.charge.low = 98
#   default.battery.charge.low  = 98

# Restart driver first (required to pick up ups.conf changes)
sudo systemctl restart nut-driver@cyberpower
sleep 3
sudo systemctl restart nut-server nut-monitor

# Verify threshold was applied
upsc cyberpower@localhost battery.charge.low   # must show 98
```

### Test — Unplug UPS from wall

Open two terminals before unplugging:

```bash
# Terminal 1 -- ups client
watch -n 2 'sudo upsc cyberpower@localhost battery.charge; sudo upsc cyberpower@localhost ups.status; secs=$(sudo upsc cyberpower@localhost battery.runtime); printf "%d min %d sec\n" $((secs / 60)) $((secs % 60))'

# Terminal 2 -- watch NUT monitor events
sudo journalctl -u nut-monitor -f

# Terminal 3 -- watch shutdown log
sudo tail -f /var/log/nut-shutdown.log
```

Then unplug the UPS from the wall outlet.

**Expected sequence:**

| Time | Event | Log |
|---|---|---|
| T+0 | UPS switches to battery | `nut-monitor: UPS on battery` |
| T+~1min | Battery drops to 98% | `nut-monitor: UPS battery is low` |
| T+~2s | FSD sent | `nut-monitor: forced shutdown in progress` |
| T+120s | Shutdown script fires | `nut-shutdown.log: === NUT shutdown triggered ===` |
| T+~10s | All KVMs/LXC stopped | `nut-shutdown.log: KVMs: done / LXCs: done` |
| T+~1s | Battery logged | `nut-shutdown.log: Battery at poweroff: charge=97%...` |
| T+~1s | Poweroff | `nut-shutdown.log: === All workloads stopped -- powering off ===` |

### After the test — check the shutdown log

```bash
cat /var/log/nut-shutdown.log
```

Look for the battery charge line at poweroff:
```
Battery at poweroff: charge=97%  runtime=6000s  status=OB DISCHRG
```

Use this to tune `NUT_BATTERY_WARN` — if you want more margin, lower the value.

### Restore — Plug UPS back in

server00 starts automatically via BIOS power-on setting.
Verify all VMs autostarted:

```bash
virsh list --all
virsh -c lxc:/// list --all
```

### Revert threshold to production value

```bash
sudo vi /etc/nut/ups.conf
# Revert: override.battery.charge.low = 20  (or your NUT_BATTERY_WARN)
#         default.battery.charge.low  = 20

sudo systemctl restart nut-driver@cyberpower
sleep 3 && sudo systemctl restart nut-server nut-monitor
upsc cyberpower@localhost battery.charge.low   # verify
```

---

## Key Log Files

| File | Purpose |
|---|---|
| `journalctl -u nut-monitor` | Power events: ONBATT, LOWBATT, FSD |
| `journalctl -u nut-server` | Driver connection, upsd events |
| `/var/log/nut-shutdown.log` | VM shutdown sequence + battery charge at poweroff |

---

## Removed Variables (site-X.env cleanup)

The following variables are **no longer needed** after moving to standalone mode
(no Pi, no NUT server on separate machine, no WOL):

```bash
# Remove from site-X.env:
NUTSERVER_HOSTNAME
NUTSERVER_IP
NUTSERVER_GW
NUTSERVER_DNS
NUTSERVER_MAC
SERVER00_MAC
SERVER00_IP
```

Also remove from `DHCP_STATIC_HOSTS` and `DNS_STATIC` in `site-X.env`:
```
dhcp-host=...,c-nutserver,...
host-record=c-nutserver.chalet.lab,...
```

Then re-run `09-create-router00.sh` to clean up dnsmasq.
