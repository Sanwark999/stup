#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[..] $1${NC}"; }
ok()   { echo -e "${GREEN}[OK] $1${NC}"; }
fail() { echo -e "${RED}[XX] $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && fail "Please run as root"

WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR"

log "Installing WireGuard and dependencies..."
apt-get update -qq
apt-get install -y wireguard wireguard-tools iptables iproute2 qrencode curl > /dev/null 2>&1
ok "Packages installed"

log "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
ok "IP forwarding enabled"

log "Detecting main network interface..."
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
[ -z "$IFACE" ] && fail "Could not detect network interface"
ok "Interface: $IFACE"

log "Detecting VPS public IP..."
VPS_IP=$(curl -sf https://api.ipify.org || curl -sf https://icanhazip.com || hostname -I | awk '{print $1}')
[ -z "$VPS_IP" ] && fail "Could not detect VPS IP"
ok "VPS IP: $VPS_IP"

log "Generating WireGuard keys..."

VPS_PRIV=$(wg genkey)
VPS_PUB=$(echo "$VPS_PRIV" | wg pubkey)

HOME_PRIV=$(wg genkey)
HOME_PUB=$(echo "$HOME_PRIV" | wg pubkey)
HOME_PSK=$(wg genpsk)

PHONE_PRIV=$(wg genkey)
PHONE_PUB=$(echo "$PHONE_PRIV" | wg pubkey)
PHONE_PSK=$(wg genpsk)

ok "Keys generated"
log "Creating WireGuard server config..."

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $VPS_PRIV

PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey = $HOME_PUB
PresharedKey = $HOME_PSK
AllowedIPs = 10.8.0.2/32

[Peer]
PublicKey = $PHONE_PUB
PresharedKey = $PHONE_PSK
AllowedIPs = 10.8.0.3/32
EOF

chmod 600 /etc/wireguard/wg0.conf
ok "Server config created"

log "Enabling and starting WireGuard..."

systemctl enable --now wg-quick@wg0
ok "WireGuard service enabled and started"

log "Creating routing helper (idempotent)..."

cat > /etc/wireguard/routing.sh << 'EOF'
#!/bin/bash
set -e

sleep 5

ip rule del from 10.8.0.3/32 table 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

ip rule add from 10.8.0.3/32 table 100 priority 50

ip route add default via 10.8.0.2 dev wg0 table 100 onlink || true
EOF

chmod +x /etc/wireguard/routing.sh
ok "Routing script created"

log "Installing cron job safely (no duplicates)..."

( crontab -l 2>/dev/null | grep -v routing.sh; echo "@reboot /etc/wireguard/routing.sh" ) | crontab -
ok "Cron configured"
log "Creating HOME client config..."

cat > /etc/wireguard/home-client.conf << EOF
[Interface]
Address = 10.8.0.2/24
DNS = 1.1.1.1
PrivateKey = $HOME_PRIV

# NAT handled on VPS, avoid double NAT rules here unless needed
Table = off

PostUp = ip rule add iif wg0 table main priority 100
PostDown = ip rule del iif wg0 table main priority 100

[Peer]
PublicKey = $VPS_PUB
PresharedKey = $HOME_PSK
Endpoint = ${VPS_IP}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/home-client.conf
ok "Home client config created"

log "Detecting phone config settings..."

PHONE_ALLOWED_IPS="0.0.0.0/0"
PHONE_DNS="1.1.1.1"

cat > /etc/wireguard/phone-client.conf << EOF
[Interface]
Address = 10.8.0.3/24
DNS = $PHONE_DNS
PrivateKey = $PHONE_PRIV

[Peer]
PublicKey = $VPS_PUB
PresharedKey = $PHONE_PSK
Endpoint = ${VPS_IP}:51820
AllowedIPs = $PHONE_ALLOWED_IPS
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/phone-client.conf
ok "Phone client config created"

log "Generating QR code for phone..."

echo ""
echo "================ PHONE QR CONFIG ================"
qrencode -t ansiutf8 < /etc/wireguard/phone-client.conf
echo "=================================================="
echo ""

echo "================ HOME CLIENT CONFIG =============="
cat /etc/wireguard/home-client.conf
echo "=================================================="

ok "Setup complete"

echo ""
echo -e "${GREEN}✔ WireGuard installation finished${NC}"
echo ""
echo "Next steps:"
echo "1. Reboot VPS:"
echo "   reboot"
echo ""
echo "2. After reboot verify:"
echo "   wg show"
echo "   systemctl status wg-quick@wg0"
echo ""
echo "3. Import phone QR into WireGuard app"
echo ""
