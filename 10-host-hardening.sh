#!/bin/bash
# 10-host-hardening.sh -- Security for Debian Host (m-server00 / c-server00)
set -euo pipefail

echo "=== [10-host-hardening] Starting Security Lockdown ==="

# 1. Update and install security tools
sudo apt update
sudo apt install -y fail2ban ufw

# 2. Hardening SSH Configuration
echo "--- Configuring SSH for Key-Only access ---"
SSH_CONF=/etc/ssh/sshd_config.d/hardening.conf
sudo bash -c "cat <<EOF > ${SSH_CONF}
# Hardening for site management
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers lab
# Listen only on internal interfaces (optional but safer)
# Port 22
EOF"

sudo systemctl restart ssh

# 3. Configure UFW Firewall (The "Security Gate")
echo "--- Configuring Host Firewall (UFW) ---"
# Default policy: Deny everything coming in, allow everything going out
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH from ALL internal subnets (10.0.x.x and 10.1.x.x)
# This covers LAN5, LAN10, VLAN20, VLAN30 and WireGuard transits
sudo ufw allow from 10.0.0.0/15 to any port 22 proto tcp comment 'Internal Management SSH'

# Temporary: Allow SSH from WiFi (if you are on a 192.168.x.x subnet during build)
# Note: On pourra retirer cette règle une fois les machines à leur site final
sudo ufw allow from 192.168.0.0/16 to any port 22 proto tcp comment 'Build phase WiFi access'

# ENABLE Firewall
echo "y" | sudo ufw enable

# 4. Configure Fail2Ban
echo "--- Configuring Fail2Ban ---"
sudo bash -c "cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = ssh
maxretry = 3
bantime  = 1h
EOF"

sudo systemctl enable --now fail2ban

echo "=== Security Hardening Complete ==="
echo "--- UFW Status ---"
sudo ufw status numbered
