#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}sudo required${NC}"; exit 1; }

echo "=========================================="
echo "🚀 AmneziaVPN Manager Installer"
echo "=========================================="

read -p "DE Server IP: " DE_IP
read -p "DE Server PUBKEY: " DE_PUBKEY
[[ -z "$DE_IP" || -z "$DE_PUBKEY" ]] && { echo "Required!"; exit 1; }

read -p "Admin login [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -s -p "Admin password: " ADMIN_PASS
echo ""
[[ -z "$ADMIN_PASS" ]] && { echo "Password required!"; exit 1; }
read -p "Web port [8080]: " WEB_PORT
WEB_PORT=${WEB_PORT:-8080}

# Install dependencies
apt-get update -qq
apt-get install -y -qq software-properties-common iptables curl wget ipset qrencode python3 python3-pip python3-venv
add-apt-repository ppa:amnezia/ppa -y
apt-get update -qq
apt-get install -y -qq amneziawg amneziawg-tools 2>/dev/null || apt-get install -y -qq amneziawg amneziawg-tools

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg.conf
sysctl -p /etc/sysctl.d/99-awg.conf

# Generate keys
mkdir -p /etc/amnezia/amneziawg && cd /etc/amnezia/amneziawg
awg genkey | tee ru_priv | awg pubkey > ru_pub
awg genkey | tee vpn_priv | awg pubkey > vpn_pub
RU_PRIV=$(cat ru_priv)
RU_PUB=$(cat ru_pub)
VPN_PRIV=$(cat vpn_priv)
VPN_PUB=$(cat vpn_pub)
RU_IP=$(curl -s -4 --max-time 5 ifconfig.me || curl -s -4 api.ipify.org)
ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

# ipset for RU IPs
cat > /usr/local/bin/update_ru_ips.sh << 'EOS'
#!/bin/bash
ipset create ru_ips hash:net 2>/dev/null || true
ipset flush ru_ips
ipset add ru_ips 10.0.0.0/8 2>/dev/null || true
ipset add ru_ips 192.168.0.0/16 2>/dev/null || true
ipset add ru_ips 172.16.0.0/12 2>/dev/null || true
curl -sL https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt | grep -v '^#' | grep -E '^[0-9]' | while read line; do ipset add ru_ips $line 2>/dev/null || true; done
EOS
chmod +x /usr/local/bin/update_ru_ips.sh
/usr/local/bin/update_ru_ips.sh

# DE tunnel
cat > awg0.conf << EOF
[Interface]
PrivateKey = $RU_PRIV
Address = 10.9.0.2/24
Table = off
MTU = 1360
Jc = 120
Jmin = 50
Jmax = 1000
S1 = 111
S2 = 222
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = $DE_PUBKEY
Endpoint = $DE_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# Client server
cat > awg-client.conf << EOF
[Interface]
PrivateKey = $VPN_PRIV
Address = 10.10.0.1/24
ListenPort = 51821
MTU = 1360
Jc = 120
Jmin = 50
Jmax = 1000
S1 = 111
S2 = 222
H1 = 1
H2 = 2
H3 = 3
H4 = 4

PostUp = /usr/local/bin/update_ru_ips.sh
PostUp = ip route add default dev awg0 table 100 2>/dev/null || true
PostUp = ip rule add fwmark 255 lookup 100 2>/dev/null || true
PostUp = iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
PostUp = iptables -t mangle -A PREROUTING -i awg-client -m set ! --match-set ru_ips dst -j MARK --set-mark 255

PostDown = ip rule del fwmark 255 lookup 100 2>/dev/null || true
PostDown = ip route flush table 100 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o $ETH -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i awg-client -m set ! --match-set ru_ips dst -j MARK --set-mark 255 2>/dev/null || true
EOF

iptables -I INPUT -p udp --dport 51821 -j ACCEPT
iptables -I INPUT -p tcp --dport $WEB_PORT -j ACCEPT
systemctl enable --now awg-quick@awg0 2>/dev/null || true
systemctl enable --now awg-quick@awg-client 2>/dev/null || true

# Web UI
INSTALL_DIR="/opt/amnezia-vpn-manager"
rm -rf $INSTALL_DIR
mkdir -p $INSTALL_DIR/frontend
cd $INSTALL_DIR

python3 -m venv venv
source venv/bin/activate
pip install -q fastapi uvicorn sqlalchemy sqlmodel pydantic pydantic-settings python-multipart qrcode pillow aiofiles httpx python-jose passlib bcrypt

# Download files
wget -q -O main.py https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/main.py
wget -q -O models.py https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/models.py
wget -q -O database.py https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/database.py
wget -q -O amneziawg.py https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/amneziawg.py
wget -q -O routing.py https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/routing.py

cd frontend
wget -q -O index.html https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/frontend/index.html
wget -q -O style.css https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/frontend/style.css
wget -q -O app.js https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/frontend/app.js
cd ..

mkdir -p config
cat > config/.env << EOF
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASS
SECRET_KEY=$(openssl rand -hex 32)
DATABASE_URL=sqlite:///$INSTALL_DIR/vpn_manager.db
EOF

# Systemd
cat > /etc/systemd/system/amnezia-vpn-manager.service << EOF
[Unit]
Description=AmneziaVPN Manager
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/config/.env
ExecStart=$INSTALL_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port $WEB_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now amnezia-vpn-manager
sleep 2

echo ""
echo "=========================================="
echo -e "${GREEN}✅ DONE!${NC}"
echo "=========================================="
echo "Web UI: http://$RU_IP:$WEB_PORT"
echo "Login: $ADMIN_USER"
echo ""
echo "Run on DE server:"
echo "  awg set awg0 peer $RU_PUB allowed-ips 10.9.0.2/32"
echo "=========================================="
