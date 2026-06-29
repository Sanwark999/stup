#!/bin/bash
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[..] $1${NC}"; }
ok()   { echo -e "${GREEN}[OK] $1${NC}"; }
fail() { echo -e "${RED}[XX] $1${NC}"; exit 1; }
[ "$EUID" -ne 0 ] && fail "Please run as root"
log "Installing WireGuard..."
apt-get update -qq && apt-get install -y wireguard wireguard-tools iptables iproute2 qrencode > /dev/null 2>&1
ok "WireGuard installed"
log "Generating keys..."
VPS_PRIV=$(wg genkey); VPS_PUB=$(echo "$VPS_PRIV" | wg pubkey)
HOME_PRIV=$(wg genkey); HOME_PUB=$(echo "$HOME_PRIV" | wg pubkey); HOME_PSK=$(wg genpsk)
PHONE_PRIV=$(wg genkey); PHONE_PUB=$(echo "$PHONE_PRIV" | wg pubkey); PHONE_PSK=$(wg genpsk)
ok "Keys generated"
IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
log "Interface: $IFACE"
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q "ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
VPS_IP=$(curl -s ifconfig.me)
mkdir -p /etc/wireguard

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address    = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $VPS_PRIV
PostUp   = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey    = $HOME_PUB
PresharedKey = $HOME_PSK
AllowedIPs   = 0.0.0.0/0

[Peer]
PublicKey    = $PHONE_PUB
PresharedKey = $PHONE_PSK
AllowedIPs   = 10.8.0.3/32
EOF

chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0 > /dev/null 2>&1
systemctl start wg-quick@wg0
sleep 2
systemctl is-active --quiet wg-quick@wg0 && ok "WireGuard running!" || fail "WireGuard failed to start"

ip rule add from 10.8.0.3/32 table 100 priority 50 2>/dev/null || true
ip route add default via 10.8.0.2 dev wg0 onlink table 100 2>/dev/null || true

cat > /etc/wireguard/routing.sh << 'ROUTEOF'
#!/bin/bash
sleep 5
ip rule add from 10.8.0.3/32 table 100 priority 50 2>/dev/null || true
ip route add default via 10.8.0.2 dev wg0 onlink table 100 2>/dev/null || true
ROUTEOF
chmod +x /etc/wireguard/routing.sh
(crontab -l 2>/dev/null; echo "@reboot /etc/wireguard/routing.sh") | crontab -

cat > /etc/wireguard/home-client.conf << EOF
[Interface]
Address    = 10.8.0.2/24
DNS        = 1.1.1.1
PrivateKey = $HOME_PRIV
Table      = off
PostUp     = ip rule add iif wg0 table main priority 100
PostUp     = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostUp     = iptables -A FORWARD -j ACCEPT
PostDown   = ip rule del iif wg0 table main priority 100
PostDown   = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PostDown   = iptables -D FORWARD -j ACCEPT

[Peer]
PublicKey           = $VPS_PUB
PresharedKey        = $HOME_PSK
Endpoint            = ${VPS_IP}:51820
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 25
EOF

cat > /etc/wireguard/phone-client.conf << EOF
[Interface]
Address    = 10.8.0.3/24
DNS        = 1.1.1.1
PrivateKey = $PHONE_PRIV

[Peer]
PublicKey           = $VPS_PUB
PresharedKey        = $PHONE_PSK
Endpoint            = ${VPS_IP}:51820
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

echo ""
echo "============================================================"
echo -e "${GREEN}  VPS Setup Complete!${NC}"
echo "============================================================"
echo ""
echo "=== HOME PC CONFIG (paste into WSL /etc/wireguard/wg0.conf) ==="
echo ""
cat /etc/wireguard/home-client.conf
echo ""
echo "=== PHONE QR CODE ==="
qrencode -t ansiutf8 < /etc/wireguard/phone-client.conf
echo ""
