#!/bin/bash
#
# Установка Exit-ноды (Германия/Зарубежный сервер)
# Запускать на чистом сервере Ubuntu 20.04/22.04
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите с sudo${NC}"
    exit 1
fi

echo "=========================================="
echo "🚀 Установка Exit-ноды AmneziaWG"
echo "=========================================="

# Обновление
log_info "Обновление системы..."
apt-get update -qq && apt-get upgrade -y -qq

# Зависимости
log_info "Установка зависимостей..."
apt-get install -y -qq software-properties-common iptables curl ca-certificates gnupg

# Репозиторий Amnezia
log_info "Добавление репозитория AmneziaWG..."
add-apt-repository ppa:amnezia/ppa -y
apt-get update -qq

# Установка AmneziaWG
log_info "Установка AmneziaWG..."
apt-get install -y -qq amneziawg amneziawg-tools linux-headers-$(uname -r) 2>/dev/null || \
    apt-get install -y -qq amneziawg amneziawg-tools

# Форвардинг
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg.conf
sysctl -p /etc/sysctl.d/99-awg.conf > /dev/null

# Ключи
mkdir -p /etc/amnezia/amneziawg && cd /etc/amnezia/amneziawg
log_info "Генерация ключей..."
awg genkey | tee privatekey | awg pubkey > publickey
PRIV=$(cat privatekey)
PUB=$(cat publickey)

ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

# Конфиг с ФИКСИРОВАННЫМИ параметрами обфускации
cat << EOC > awg0.conf
[Interface]
PrivateKey = $PRIV
Address = 10.9.0.1/24
ListenPort = 51820
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
PostUp = iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o $ETH -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o $ETH -j MASQUERADE
EOC

# Фаервол
iptables -I INPUT -p udp --dport 51820 -j ACCEPT
ufw allow 51820/udp 2>/dev/null || true

# Запуск
log_info "Запуск AmneziaWG..."
systemctl enable --now awg-quick@awg0

EXTERNAL_IP=$(curl -s -4 --max-time 5 ifconfig.me || curl -s -4 --max-time 5 api.ipify.org)

echo ""
echo "=========================================="
echo -e "${GREEN}✅ DE-СЕРВЕР ГОТОВ!${NC}"
echo "=========================================="
echo ""
echo -e "${YELLOW}Для RU-сервера введите:${NC}"
echo ""
echo "  IP:      $EXTERNAL_IP"
echo "  PUBKEY:  $PUB"
echo ""
echo "=========================================="
