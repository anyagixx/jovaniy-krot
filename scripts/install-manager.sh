#!/bin/bash
#
# Скрипт установки только Web UI Manager
# Для использования на уже настроенном RU-сервере
#

set -e

echo "=========================================="
echo "🖥️  Установка AmneziaVPN Manager Web UI"
echo "=========================================="

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт с правами root (sudo)"
    exit 1
fi

# Настройки
read -p "Логин для Web UI [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Пароль для Web UI: " ADMIN_PASS
echo ""
if [[ -z "$ADMIN_PASS" ]]; then
    echo "Пароль обязателен!"
    exit 1
fi

read -p "Порт для Web UI [8080]: " WEB_PORT
WEB_PORT=${WEB_PORT:-8080}

# Установка зависимостей
log_info "Установка зависимостей..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv git curl

# Создание директории
INSTALL_DIR="/opt/amnezia-vpn-manager"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Клонирование или копирование файлов
if [[ -d "/tmp/amnezia-vpn-manager" ]]; then
    cp -r /tmp/amnezia-vpn-manager/* $INSTALL_DIR/
else
    # Создаем структуру если файлов нет
    mkdir -p backend frontend config
fi

# Создание виртуального окружения
log_info "Создание виртуального окружения..."
python3 -m venv venv
source venv/bin/activate

# Установка Python зависимостей
log_info "Установка Python пакетов..."
pip install --upgrade pip -q
pip install \
    fastapi \
    uvicorn[standard] \
    sqlalchemy \
    sqlmodel \
    pydantic \
    pydantic-settings \
    python-multipart \
    qrcode[pil] \
    aiofiles \
    httpx \
    python-jose[cryptography] \
    passlib[bcrypt] \
    -q

# Создание конфигурации
log_info "Создание конфигурации..."
RU_IP=$(curl -s -4 --max-time 5 ifconfig.me || curl -s -4 --max-time 5 api.ipify.org)

cat << ENV > $INSTALL_DIR/config/.env
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASS
SECRET_KEY=$(openssl rand -hex 32)
DATABASE_URL=sqlite:///$INSTALL_DIR/vpn_manager.db
WEB_PORT=$WEB_PORT
RU_IP=$RU_IP
ENV

# Создание systemd сервиса
log_info "Создание systemd сервиса..."
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

# Настройка фаервола
iptables -I INPUT -p tcp --dport $WEB_PORT -j ACCEPT 2>/dev/null || true
if command -v ufw &> /dev/null; then
    ufw allow $WEB_PORT/tcp 2>/dev/null || true
fi

# Запуск
systemctl daemon-reload
systemctl enable --now amnezia-vpn-manager

# Результат
echo ""
echo "=========================================="
echo -e "${GREEN}✅ Web UI УСТАНОВЛЕН!${NC}"
echo "=========================================="
echo ""
echo -e "🌐 Адрес: ${YELLOW}http://$RU_IP:$WEB_PORT${NC}"
echo -e "👤 Логин: ${YELLOW}$ADMIN_USER${NC}"
echo ""
echo "📁 Директория: $INSTALL_DIR"
echo "🔄 Перезапуск: systemctl restart amnezia-vpn-manager"
echo "📋 Логи: journalctl -u amnezia-vpn-manager -f"
echo ""
