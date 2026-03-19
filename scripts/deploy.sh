#!/bin/bash
#
# Быстрый деплой проекта на сервер
# Использование: ./deploy.sh user@server-ip
#

set -e

if [[ -z "$1" ]]; then
    echo "Использование: $0 user@server-ip"
    exit 1
fi

SERVER=$1
REMOTE_DIR="/tmp/amnezia-vpn-manager"

echo "📦 Подготовка файлов..."
# Копируем только нужные файлы
rsync -avz --progress \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='.git' \
    --exclude='data' \
    --exclude='*.db' \
    --exclude='venv' \
    ../amnezia-vpn-manager/ ${SERVER}:${REMOTE_DIR}/

echo "🚀 Файлы загружены на сервер: ${SERVER}:${REMOTE_DIR}"
echo ""
echo "Теперь выполните на сервере:"
echo "  cd ${REMOTE_DIR}"
echo "  sudo ./scripts/install-ru.sh"
