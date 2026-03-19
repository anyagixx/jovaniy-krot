#!/bin/bash
#
# Скрипт установки RU-сервера с split-tunneling и Web UI
# Запускать на чистом сервере с Ubuntu 20.04/22.04
#

set -e

echo "=========================================="
echo "🚀 Установка RU-сервера AmneziaWG Manager"
echo "=========================================="

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    log_error "Запустите скрипт с правами root (sudo)"
    exit 1
fi

# Запрос параметров
echo ""
read -p "Введите IP-адрес DE-сервера: " DE_IP
read -p "Введите публичный ключ DE-сервера: " DE_PUBKEY
read -p "Введите параметры обфускации DE (Jc:Jmin:Jmax:S1:S2:H1:H2:H3:H4) или Enter для авто: " OBFUSCATION

# Парсинг параметров обфускации
if [[ -n "$OBFUSCATION" ]]; then
    IFS=':' read -r JC JMIN JMAX S1 S2 H1 H2 H3 H4 <<< "$OBFUSCATION"
else
    JC=120; JMIN=50; JMAX=1000; S1=111; S2=222; H1=1; H2=2; H3=3; H4=4
fi

# Настройки Web UI
read -p "Логин для Web UI [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Пароль для Web UI: " ADMIN_PASS
echo ""
if [[ -z "$ADMIN_PASS" ]]; then
    log_error "Пароль обязателен!"
    exit 1
fi

read -p "Порт для Web UI [8080]: " WEB_PORT
WEB_PORT=${WEB_PORT:-8080}

# ========================================
# 1. Обновление системы
# ========================================
log_step "1/8 Обновление системы..."
apt-get update -qq
apt-get upgrade -y -qq

# ========================================
# 2. Установка зависимостей
# ========================================
log_step "2/8 Установка зависимостей..."
apt-get install -y -qq \
    software-properties-common \
    iptables \
    iproute2 \
    curl \
    wget \
    ipset \
    qrencode \
    python3 \
    python3-pip \
    python3-venv \
    git \
    ca-certificates \
    gnupg

# ========================================
# 3. Установка AmneziaWG
# ========================================
log_step "3/8 Установка AmneziaWG..."
if ! command -v awg &> /dev/null; then
    add-apt-repository ppa:amnezia/ppa -y
    apt-get update -qq
    apt-get install -y -qq amneziawg amneziawg-tools linux-headers-$(uname -r) || {
        apt-get install -y -qq amneziawg amneziawg-tools
    }
fi

# Включение форвардинга
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg.conf
sysctl -p /etc/sysctl.d/99-awg.conf > /dev/null

# ========================================
# 4. Генерация ключей
# ========================================
log_step "4/8 Генерация ключей..."
mkdir -p /etc/amnezia/amneziawg
cd /etc/amnezia/amneziawg

# Ключи для туннеля до DE
awg genkey | tee ru_priv | awg pubkey > ru_pub

# Ключи для сервера клиентов
awg genkey | tee vpn_priv | awg pubkey > vpn_pub

RU_PRIV=$(cat ru_priv)
RU_PUB=$(cat ru_pub)
VPN_PRIV=$(cat vpn_priv)
VPN_PUB=$(cat vpn_pub)

# Получение внешнего IP
RU_IP=$(curl -s -4 --max-time 5 ifconfig.me || curl -s -4 --max-time 5 api.ipify.org)
ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

log_info "Внешний IP: $RU_IP"
log_info "Интерфейс: $ETH"

# ========================================
# 5. Настройка ipset для РФ IP
# ========================================
log_step "5/8 Настройка списков IP России..."

cat << 'EOS' > /usr/local/bin/update_ru_ips.sh
#!/bin/bash
# Обновление списка IP-адресов России
IPSET_NAME="ru_ips"

# Создаем ipset если не существует
ipset create $IPSET_NAME hash:net 2>/dev/null || true
ipset flush $IPSET_NAME

# Добавляем локальные сети
ipset add $IPSET_NAME 10.0.0.0/8 2>/dev/null || true
ipset add $IPSET_NAME 192.168.0.0/16 2>/dev/null || true
ipset add $IPSET_NAME 172.16.0.0/12 2>/dev/null || true

# Загружаем список IP России
curl -sL https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt 2>/dev/null | \
    grep -v '^#' | grep -E '^[0-9]' | \
    while read line; do
        ipset add $IPSET_NAME $line 2>/dev/null || true
    done

echo "IPset updated: $(ipset list $IPSET_NAME | grep 'Number of entries' | awk '{print $4}') entries"
EOS
chmod +x /usr/local/bin/update_ru_ips.sh

# Первичное обновление
/usr/local/bin/update_ru_ips.sh

# Добавляем в cron (ежедневно)
(crontab -l 2>/dev/null | grep -v update_ru_ips; echo "0 3 * * * /usr/local/bin/update_ru_ips.sh >> /var/log/ru_ips.log 2>&1") | crontab -

# ========================================
# 6. Настройка туннеля до DE
# ========================================
log_step "6/8 Настройка туннеля до DE-сервера..."

cat << EOC > awg0.conf
[Interface]
PrivateKey = $RU_PRIV
Address = 10.9.0.2/24
Table = off
MTU = 1360
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $DE_PUBKEY
Endpoint = $DE_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOC

# ========================================
# 7. Настройка сервера для клиентов
# ========================================
log_step "7/8 Настройка VPN сервера для клиентов..."

cat << EOC > awg-client.conf
[Interface]
PrivateKey = $VPN_PRIV
Address = 10.10.0.1/24
ListenPort = 51821
MTU = 1360
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

# Split-tunneling: РФ трафик напрямую, остальное через DE
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

# Настройка фаервола
iptables -I INPUT -p udp --dport 51821 -j ACCEPT
iptables -I INPUT -p tcp --dport $WEB_PORT -j ACCEPT
if command -v ufw &> /dev/null; then
    ufw allow 51821/udp 2>/dev/null || true
    ufw allow $WEB_PORT/tcp 2>/dev/null || true
fi

# Запуск сервисов
log_info "Запуск туннеля до DE..."
systemctl enable --now awg-quick@awg0

log_info "Запуск VPN сервера..."
systemctl enable --now awg-quick@awg-client

# ========================================
# 8. Установка Web UI
# ========================================
log_step "8/8 Установка Web UI..."

# Создание директории
INSTALL_DIR="/opt/amnezia-vpn-manager"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Создание виртуального окружения
python3 -m venv venv
source venv/bin/activate

# Установка зависимостей
pip install --upgrade pip -q
pip install fastapi uvicorn sqlalchemy sqlmodel pydantic pydantic-settings \
    python-multipart qrcode pillow aiofiles httpx python-jose passlib bcrypt -q

# Копирование файлов (если есть)
if [[ -d "/tmp/amnezia-vpn-manager" ]]; then
    cp -r /tmp/amnezia-vpn-manager/* $INSTALL_DIR/
fi

# Создание конфигурации
mkdir -p $INSTALL_DIR/config
cat << ENV > $INSTALL_DIR/config/.env
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
SECRET_KEY=$(openssl rand -hex 32)
DATABASE_URL=sqlite:///$INSTALL_DIR/vpn_manager.db
WEB_PORT=$WEB_PORT
DE_IP=$DE_IP
DE_PUBKEY=$DE_PUBKEY
RU_IP=$RU_IP
RU_PUBKEY=$RU_PUB
VPN_PUBKEY=$VPN_PUB
ENV

# Создание systemd сервиса
cat << SERVICE > /etc/systemd/system/amnezia-vpn-manager.service
[Unit]
Description=AmneziaVPN Manager Web UI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/config/.env
ExecStart=$INSTALL_DIR/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port $WEB_PORT
Restart=always
RestartSec=5

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
echo -e "${GREEN}✅ RU-СЕРВЕР УСТАНОВЛЕН!${NC}"
echo "=========================================="
echo ""
echo -e "🌐 Web UI: ${YELLOW}http://$RU_IP:$WEB_PORT${NC}"
echo -e "👤 Логин: ${YELLOW}$ADMIN_USER${NC}"
echo ""
echo "=========================================="
echo ""
echo "⚠️  ВАЖНО: Выполните на DE-сервере команду:"
echo ""
echo -e "  ${GREEN}awg set awg0 peer $RU_PUB allowed-ips 10.9.0.2/32${NC}"
echo ""
echo "Или добавьте в /etc/amnezia/amneziawg/awg0.conf на DE-сервере:"
echo ""
echo '  [Peer]'
echo "  PublicKey = $RU_PUB"
echo '  AllowedIPs = 10.9.0.2/32'
echo ""
echo "=========================================="
echo ""
echo "📁 Файлы конфигурации:"
echo "   - VPN: /etc/amnezia/amneziawg/"
echo "   - Web UI: $INSTALL_DIR/"
echo "   - Логи: journalctl -u amnezia-vpn-manager -f"
echo ""
echo "🔄 Перезапуск Web UI: systemctl restart amnezia-vpn-manager"
echo ""
