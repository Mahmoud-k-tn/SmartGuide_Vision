#!/bin/bash
# scripts/install.sh ï¿½ SmartGuide Pi full setup
# Run once on a fresh Pi OS Lite 64-bit Bookworm install.
# sudo ./scripts/install.sh

set -e
echo "=== SmartGuide Pi Setup ==="

# -- system packages -----------------------------------------------------------
apt-get update -y
apt-get install -y \
    python3-pip \
    python3-venv \
    python3-opencv \
    hostapd \
    dnsmasq \
    git

# -- Python dependencies -------------------------------------------------------
pip3 install --break-system-packages \
    websockets \
    numpy \
    tflite-runtime

# -- WiFi hotspot setup --------------------------------------------------------
echo "=== Configuring WiFi hotspot ==="

# Stop services first
systemctl stop hostapd dnsmasq 2>/dev/null || true

# hostapd config
cat > /etc/hostapd/hostapd.conf << EOF
interface=wlan0
driver=nl80211
ssid=SmartGuide-Device
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=smartguide2025
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# Point hostapd to config
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd

# dnsmasq config
cat > /etc/dnsmasq.conf << EOF
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
EOF

# Static IP for wlan0
cat >> /etc/dhcpcd.conf << EOF
interface wlan0
    static ip_address=192.168.4.1/24
    nohook wpa_supplicant
EOF

# Enable and start
systemctl unmask hostapd
systemctl enable hostapd dnsmasq
systemctl start hostapd dnsmasq

echo "=== Hotspot configured: SmartGuide-Device / smartguide2025 ==="

# -- systemd service -----------------------------------------------------------
echo "=== Configuring systemd autostart ==="

INSTALL_DIR=$(pwd)

cat > /etc/systemd/system/smartguide.service << EOF
[Unit]
Description=SmartGuide Vision Pi Service
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable smartguide
systemctl start smartguide

echo ""
echo "=== Setup complete ==="
echo "Hotspot : SmartGuide-Device / smartguide2025"
echo "Pi IP   : 192.168.4.1"
echo "WS port : 8765"
echo "Service : systemctl status smartguide"
