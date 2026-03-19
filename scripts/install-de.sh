#!/bin/bash
#
# Скрипт установки Exit-ноды (Германия/Зарубежный сервер)
# Запускать на чистом сервере с Ubuntu 20.04/22.04
#

set -e

echo "=========================================="
echo "🚀 Установка Exit-ноды AmneziaWG"
echo "=========================================="

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    log_error "Запустите скрипт с правами root (sudo)"
    exit 1
fi

# 1. Обновление системы
log_info "Обновление системы..."
apt-get update -qq
apt-get upgrade -y -qq

# 2. Установка зависимостей
log_info "Установка зависимостей..."
apt-get install -y -qq software-properties-common iptables curl ca-certificates gnupg

# 3. Добавление репозитория Amnezia
log_info "Добавление репозитория AmneziaWG..."
if ! grep -q "amnezia" /etc/apt/sources.list.d/*.list 2>/dev/null; then
    add-apt-repository ppa:amnezia/ppa -y
fi

apt-get update -qq

# 4. Установка AmneziaWG
log_info "Установка AmneziaWG..."
apt-get install -y -qq amneziawg amneziawg-tools linux-headers-$(uname -r) || {
    log_warn "Не удалось установить linux-headers, пробуем без них..."
    apt-get install -y -qq amneziawg amneziawg-tools
}

# 5. Включение форвардинга
log_info "Настройка форвардинга пакетов..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg.conf
sysctl -p /etc/sysctl.d/99-awg.conf > /dev/null

# 6. Создание директории для конфигов
mkdir -p /etc/amnezia/amneziawg
cd /etc/amnezia/amneziawg

# 7. Генерация ключей сервера
log_info "Генерация ключей..."
awg genkey | tee privatekey | awg pubkey > publickey
PRIV=$(cat privatekey)
PUB=$(cat publickey)

# 8. Определение сетевого интерфейса
ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
log_info "Сетевой интерфейс: $ETH"

# 9. Генерация случайных параметров обфускации
JC=$((100 + RANDOM % 100))
JMIN=$((40 + RANDOM % 30))
JMAX=$((800 + RANDOM % 400))
S1=$((100 + RANDOM % 200))
S2=$((100 + RANDOM % 200))
H1=$((1 + RANDOM % 100))
H2=$((1 + RANDOM % 100))
H3=$((1 + RANDOM % 100))
H4=$((1 + RANDOM % 100))

# 10. Создание конфига
log_info "Создание конфигурации..."
cat << EOC > awg0.conf
[Interface]
PrivateKey = $PRIV
Address = 10.9.0.1/24
ListenPort = 51820
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
PostUp = iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o $ETH -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o $ETH -j MASQUERADE
EOC

# 11. Настройка фаервола
log_info "Настройка фаервола..."
iptables -I INPUT -p udp --dport 51820 -j ACCEPT
if command -v ufw &> /dev/null; then
    ufw allow 51820/udp 2>/dev/null || true
fi

# 12. Запуск сервиса
log_info "Запуск AmneziaWG..."
systemctl enable --now awg-quick@awg0

# 13. Получение внешнего IP
EXTERNAL_IP=$(curl -s -4 --max-time 5 ifconfig.me || curl -s -4 --max-time 5 api.ipify.org || echo "UNKNOWN")

# 14. Вывод результатов
echo ""
echo "=========================================="
echo -e "${GREEN}✅ EXIT-НОДА УСТАНОВЛЕНА!${NC}"
echo "=========================================="
echo ""
echo "📝 Сохраните эти данные для настройки RU-сервера:"
echo ""
echo -e "  ${YELLOW}DE_IP:${NC}        $EXTERNAL_IP"
echo -e "  ${YELLOW}DE_PUBKEY:${NC}    $PUB"
echo ""
echo -e "  ${YELLOW}Параметры обфускации:${NC}"
echo "    Jc=$JC, Jmin=$JMIN, Jmax=$JMAX"
echo "    S1=$S1, S2=$S2"
echo "    H1=$H1, H2=$H2, H3=$H3, H4=$H4"
echo ""
echo "=========================================="
echo ""
echo "Для добавления RU-сервера выполните на этом сервере:"
echo ""
echo -e "  ${GREEN}awg set awg0 peer <RU_PUBKEY> allowed-ips 10.9.0.2/32${NC}"
echo ""
echo "Или добавьте в /etc/amnezia/amneziawg/awg0.conf:"
echo ""
echo '  [Peer]'
echo '  PublicKey = <RU_PUBKEY>'
echo '  AllowedIPs = 10.9.0.2/32'
echo ""
echo "=========================================="
