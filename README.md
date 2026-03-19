# 🛡️ AmneziaVPN Manager

Web-интерфейс для управления AmneziaWG VPN с split-tunneling.

## 🚀 Установка (2 шага)

### Шаг 1: DE-сервер (Германия)

```bash
wget https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/scripts/install-de.sh
chmod +x install-de.sh
sudo ./install-de.sh
```

Сохраните **IP** и **PUBKEY** которые выдаст скрипт.

### Шаг 2: RU-сервер (Россия)

```bash
wget https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/scripts/install-ru.sh
chmod +x install-ru.sh
sudo ./install-ru.sh
```

Введите:
- IP DE-сервера
- PUBKEY DE-сервера
- Логин/пароль для Web UI

### Шаг 3: Связка

Выполните команду с вывода RU-скрипта **на DE-сервере**:

```bash
awg set awg0 peer <RU_PUBKEY> allowed-ips 10.9.0.2/32
```

### Готово!

Откройте `http://<RU_IP>:8080` — добавляйте клиентов через Web UI.

## ✨ Возможности

| Функция | Описание |
|---------|----------|
| 📱 Клиенты | Добавление/удаление через Web UI |
| 📊 QR-коды | Автогенерация для мобильных |
| 📥 .conf файлы | Для desktop клиентов |
| 🔀 Split-tunneling | РФ трафик напрямую, остальное через DE |
| 🛡 Обфускация | AmneziaWG (Jc, S1, S2, H1-H4) |

## 📱 Клиенты

- **Android:** [AmneziaWG](https://play.google.com/store/apps/details?id=org.amnezia.awg)
- **Desktop:** [AmneziaVPN](https://amnezia.org/)

## 🔧 Обслуживание

```bash
# Логи
journalctl -u amnezia-vpn-manager -f

# Перезапуск Web UI
systemctl restart amnezia-vpn-manager

# Обновить IP России
/usr/local/bin/update_ru_ips.sh

# Статус VPN
awg show
```

## 🐳 Docker

```bash
git clone https://github.com/anyagixx/jovaniy-krot.git
cd jovaniy-krot
cp config/.env.example .env
# Отредактируйте .env
docker-compose up -d
```

## 📄 Лицензия

MIT
