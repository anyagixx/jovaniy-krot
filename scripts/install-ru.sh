#!/bin/bash
#
# Установка RU-сервера с Web UI
# Запускать на чистом сервере Ubuntu 20.04/22.04
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите с sudo${NC}"
    exit 1
fi

echo ""
echo "=========================================="
echo "🚀 Установка RU-сервера AmneziaVPN"
echo "=========================================="
echo ""

# Ввод данных DE-сервера
read -p "IP DE-сервера: " DE_IP
read -p "PUBKEY DE-сервера: " DE_PUBKEY

if [[ -z "$DE_IP" || -z "$DE_PUBKEY" ]]; then
    echo -e "${RED}IP и PUBKEY обязательны!${NC}"
    exit 1
fi

# Web UI настройки
echo ""
read -p "Логин админки [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Пароль админки: " ADMIN_PASS
echo ""
if [[ -z "$ADMIN_PASS" ]]; then
    echo -e "${RED}Пароль обязателен!${NC}"
    exit 1
fi

read -p "Порт админки [8080]: " WEB_PORT
WEB_PORT=${WEB_PORT:-8080}

# ========================================
# Установка
# ========================================

log_step "1/7 Обновление системы..."
apt-get update -qq && apt-get upgrade -y -qq

log_step "2/7 Установка зависимостей..."
apt-get install -y -qq software-properties-common iptables iproute2 curl wget ipset qrencode \
    python3 python3-pip python3-venv git ca-certificates gnupg

log_step "3/7 Установка AmneziaWG..."
add-apt-repository ppa:amnezia/ppa -y
apt-get update -qq
apt-get install -y -qq amneziawg amneziawg-tools linux-headers-$(uname -r) 2>/dev/null || \
    apt-get install -y -qq amneziawg amneziawg-tools

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg.conf
sysctl -p /etc/sysctl.d/99-awg.conf > /dev/null

log_step "4/7 Генерация ключей..."
mkdir -p /etc/amnezia/amneziawg && cd /etc/amnezia/amneziawg

awg genkey | tee ru_priv | awg pubkey > ru_pub
awg genkey | tee vpn_priv | awg pubkey > vpn_pub

RU_PRIV=$(cat ru_priv)
RU_PUB=$(cat ru_pub)
VPN_PRIV=$(cat vpn_priv)
VPN_PUB=$(cat vpn_pub)

RU_IP=$(curl -s -4 --max-time 5 ifconfig.me || curl -s -4 --max-time 5 api.ipify.org)
ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

log_step "5/7 Настройка ipset (IP России)..."

cat << 'EOS' > /usr/local/bin/update_ru_ips.sh
#!/bin/bash
ipset create ru_ips hash:net 2>/dev/null || true
ipset flush ru_ips
ipset add ru_ips 10.0.0.0/8 2>/dev/null || true
ipset add ru_ips 192.168.0.0/16 2>/dev/null || true
ipset add ru_ips 172.16.0.0/12 2>/dev/null || true
curl -sL https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt | \
    grep -v '^#' | grep -E '^[0-9]' | while read line; do ipset add ru_ips $line 2>/dev/null || true; done
EOS
chmod +x /usr/local/bin/update_ru_ips.sh
/usr/local/bin/update_ru_ips.sh
(crontab -l 2>/dev/null | grep -v update_ru_ips; echo "0 3 * * * /usr/local/bin/update_ru_ips.sh") | crontab -

log_step "6/7 Настройка VPN..."

# Туннель до DE (ФИКСИРОВАННЫЕ параметры обфускации)
cat << EOC > awg0.conf
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
EOC

# Сервер для клиентов
cat << EOC > awg-client.conf
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
EOC

# Фаервол
iptables -I INPUT -p udp --dport 51821 -j ACCEPT
iptables -I INPUT -p tcp --dport $WEB_PORT -j ACCEPT
ufw allow 51821/udp 2>/dev/null || true
ufw allow $WEB_PORT/tcp 2>/dev/null || true

# Запуск VPN
systemctl enable --now awg-quick@awg0
systemctl enable --now awg-quick@awg-client

log_step "7/7 Установка Web UI..."

INSTALL_DIR="/opt/amnezia-vpn-manager"
mkdir -p $INSTALL_DIR && cd $INSTALL_DIR

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install fastapi uvicorn sqlalchemy sqlmodel pydantic pydantic-settings \
    python-multipart qrcode pillow aiofiles httpx python-jose passlib bcrypt -q

# Скачивание файлов с GitHub
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/main.py -O backend_main.py
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/models.py -O backend_models.py
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/database.py -O backend_database.py
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/amneziawg.py -O backend_amneziawg.py
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/backend/routing.py -O backend_routing.py

mkdir -p backend frontend
mv backend_*.py backend/ 2>/dev/null || true

cd frontend
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/frontend/index.html
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/frontend/style.css
wget -q https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/frontend/app.js
cd ..

# Конфиг
mkdir -p config
cat << ENV > config/.env
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASS
SECRET_KEY=$(openssl rand -hex 32)
DATABASE_URL=sqlite:///$INSTALL_DIR/vpn_manager.db
WEB_PORT=$WEB_PORT
ENV

# Systemd сервис
cat << SERVICE > /etc/systemd/system/amnezia-vpn-manager.service
[Unit]
Description=AmneziaVPN Manager
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/config/.env
ExecStart=$INSTALL_DIR/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port $WEB_PORT
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now amnezia-vpn-manager

# ========================================
# Результат
# ========================================

echo ""
echo "=========================================="
echo -e "${GREEN}✅ RU-СЕРВЕР ГОТОВ!${NC}"
echo "=========================================="
echo ""
echo -e "🌐 Web UI: ${YELLOW}http://$RU_IP:$WEB_PORT${NC}"
echo -e "👤 Логин: ${YELLOW}$ADMIN_USER${NC}"
echo ""
echo "=========================================="
echo -e "${YELLOW}⚠️  ВЫПОЛНИТЕ НА DE-СЕРВЕРЕ:${NC}"
echo ""
echo -e "  ${GREEN}awg set awg0 peer $RU_PUB allowed-ips 10.9.0.2/32${NC}"
echo ""
echo "=========================================="
