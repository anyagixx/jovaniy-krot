#!/bin/bash
#
# CLI утилита для управления AmneziaVPN
# Использование: ./cli.sh [команда] [аргументы]
#

CONFIG_DIR="/etc/amnezia/amneziawg"
SERVER_INTERFACE="awg-client"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    echo "AmneziaVPN CLI Manager"
    echo ""
    echo "Команды:"
    echo "  list              - Список всех клиентов"
    echo "  add <имя>         - Добавить клиента"
    echo "  remove <имя>      - Удалить клиента"
    echo "  show <имя>        - Показать конфиг клиента"
    echo "  qr <имя>          - Показать QR-код клиента"
    echo "  stats             - Статистика сервера"
    echo ""
}

list_clients() {
    log_info "Список клиентов:"
    awg show $SERVER_INTERFACE peers 2>/dev/null || echo "Нет клиентов"
}

add_client() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "Укажите имя клиента"
        exit 1
    fi
    
    log_info "Создание клиента: $name"
    cd $CONFIG_DIR
    
    priv=$(awg genkey)
    pub=$(echo "$priv" | awg pubkey)
    address="10.10.0.$((RANDOM % 200 + 2))"
    server_pub=$(cat vpn_pub 2>/dev/null)
    endpoint=$(curl -s -4 --max-time 5 ifconfig.me)
    
    echo "" >> $CONFIG_DIR/$SERVER_INTERFACE.conf
    echo "[Peer]" >> $CONFIG_DIR/$SERVER_INTERFACE.conf
    echo "# $name" >> $CONFIG_DIR/$SERVER_INTERFACE.conf
    echo "PublicKey = $pub" >> $CONFIG_DIR/$SERVER_INTERFACE.conf
    echo "AllowedIPs = $address/32" >> $CONFIG_DIR/$SERVER_INTERFACE.conf
    
    cat > /root/${name}.conf << EOF
[Interface]
PrivateKey = $priv
Address = $address/32
DNS = 8.8.8.8, 1.1.1.1
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
PublicKey = $server_pub
Endpoint = $endpoint:51821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    awg set $SERVER_INTERFACE peer $pub allowed-ips $address/32 2>/dev/null || true
    log_info "Клиент создан: $name -> /root/${name}.conf"
}

remove_client() {
    local name="$1"
    log_info "Удаление клиента: $name"
    rm -f /root/${name}.conf
    log_info "Удалено (перезапустите сервис для применения)"
}

show_client() {
    local name="$1"
    cat /root/${name}.conf 2>/dev/null || log_error "Конфиг не найден"
}

show_qr() {
    local name="$1"
    qrencode -t ANSIUTF8 < /root/${name}.conf 2>/dev/null || log_error "Конфиг не найден"
}

show_stats() {
    log_info "Статистика:"
    awg show
}

case "$1" in
    list)   list_clients ;;
    add)    add_client "$2" ;;
    remove) remove_client "$2" ;;
    show)   show_client "$2" ;;
    qr)     show_qr "$2" ;;
    stats)  show_stats ;;
    *)      show_help ;;
esac
