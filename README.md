# 🛡️ AmneziaVPN Manager

Web-интерфейс для управления AmneziaWG VPN с split-tunneling (РФ трафик напрямую, остальное через зарубежный сервер).

![Dashboard](https://via.placeholder.com/800x400?text=AmneziaVPN+Manager+Dashboard)

## 🌟 Возможности

- 📱 **Управление клиентами** — добавление, удаление, включение/выключение через Web UI
- 📊 **Мониторинг** — статистика трафика, статус подключений
- 🔀 **Split-tunneling** — российский трафик идет напрямую, остальное через DE-сервер
- 🛡 **Обфускация** — AmneziaWG с параметрами Jc, S1, S2, H1-H4
- 📥 **QR-коды** — генерация QR для мобильных клиентов
- 🔐 **Авторизация** — защита админки JWT-токеном

## 📋 Архитектура

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Клиенты   │ ──VPN──▶│  RU-сервер  │ ──туннель─▶│  DE-сервер  │
│ (телефон,   │         │  + Web UI   │         │  (exit node)│
│  ноутбук)   │         │             │         │             │
└─────────────┘         └─────────────┘         └─────────────┘
                              │
                              ▼
                        ┌─────────────┐
                        │ ipset РФ IP │
                        │ (прямой     │
                        │  маршрут)   │
                        └─────────────┘
```

**Маршрутизация:**
- IP России → напрямую через провайдера
- Остальной трафик → через туннель в Германию

## 🚀 Быстрая установка

### Шаг 1: DE-сервер (Германия/Зарубежный)

```bash
# На чистом сервере Ubuntu 20.04/22.04
wget https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/scripts/install-de.sh
chmod +x install-de.sh
sudo ./install-de.sh
```

Сохраните выведенные данные:
- `DE_IP` — IP-адрес сервера
- `DE_PUBKEY` — публичный ключ
- Параметры обфускации

### Шаг 2: RU-сервер (Россия)

```bash
# На чистом сервере Ubuntu 20.04/22.04
wget https://raw.githubusercontent.com/anyagixx/jovaniy-krot/main/scripts/install-ru.sh
chmod +x install-ru.sh
sudo ./install-ru.sh
```

Введите запрошенные данные:
- IP и ключ DE-сервера
- Параметры обфускации (должны совпадать с DE)
- Логин/пароль для Web UI

### Шаг 3: Связывание серверов

Выполните на DE-сервере команду, которую выдаст скрипт установки RU:

```bash
awg set awg0 peer <RU_PUBKEY> allowed-ips 10.9.0.2/32
```

### Шаг 4: Готово!

Откройте Web UI: `http://<RU_IP>:8080`

## 📁 Структура проекта

```
amnezia-vpn-manager/
├── backend/
│   ├── main.py           # FastAPI приложение
│   ├── models.py         # Модели базы данных
│   ├── database.py       # Подключение к БД
│   ├── amneziawg.py      # Управление AmneziaWG
│   ├── routing.py        # Split-tunneling логика
│   └── requirements.txt  # Python зависимости
├── frontend/
│   ├── index.html        # Web UI
│   ├── style.css         # Стили
│   └── app.js            # JavaScript
├── scripts/
│   ├── install-de.sh     # Установка DE-сервера
│   ├── install-ru.sh     # Установка RU-сервера + Web UI
│   └── install-manager.sh # Только Web UI
├── config/
│   └── .env.example      # Пример конфигурации
├── Dockerfile
├── docker-compose.yml
└── README.md
```

## 🔧 API Endpoints

| Endpoint | Method | Описание |
|----------|--------|----------|
| `/api/auth/login` | POST | Авторизация |
| `/api/clients` | GET | Список клиентов |
| `/api/clients` | POST | Создать клиента |
| `/api/clients/{id}` | DELETE | Удалить клиента |
| `/api/clients/{id}/qr` | GET | QR-код клиента |
| `/api/clients/{id}/config` | GET | Скачать конфиг |
| `/api/clients/{id}/toggle` | POST | Вкл/выкл клиента |
| `/api/stats` | GET | Статистика сервера |
| `/api/routing/status` | GET | Статус маршрутизации |
| `/api/routing/update-ips` | POST | Обновить IP России |

## 🐳 Docker

```bash
# Клонирование
git clone https://github.com/anyagixx/jovaniy-krot.git
cd amnezia-vpn-manager

# Конфигурация
cp config/.env.example .env
nano .env

# Запуск
docker-compose up -d
```

## 🔒 Безопасность

1. **Измените пароль по умолчанию** — используйте сложный пароль
2. **Сгенерируйте SECRET_KEY** — `openssl rand -hex 32`
3. **Настройте HTTPS** — используйте nginx с Let's Encrypt
4. **Ограничьте доступ** — настройте firewall

### Пример nginx с HTTPS:

```nginx
server {
    listen 443 ssl;
    server_name vpn.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/vpn.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vpn.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 📱 Подключение клиентов

### Мобильные устройства (AmneziaWG)

1. Скачайте [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-android) из Google Play
2. В Web UI нажмите "+ Добавить клиента"
3. Отсканируйте QR-код
4. Подключитесь!

### Desktop (AmneziaVPN)

1. Скачайте [AmneziaVPN](https://amnezia.org/)
2. В Web UI создайте клиента и скачайте `.conf` файл
3. Импортируйте конфиг в приложение
4. Подключитесь!

## 🔄 Обслуживание

```bash
# Просмотр логов Web UI
journalctl -u amnezia-vpn-manager -f

# Перезапуск Web UI
systemctl restart amnezia-vpn-manager

# Обновление IP России вручную
/usr/local/bin/update_ru_ips.sh

# Статус VPN туннелей
awg show

# Перезапуск VPN
systemctl restart awg-quick@awg0
systemctl restart awg-quick@awg-client
```

## ❓ Частые вопросы

**Q: Звонки в Telegram не работают?**
A: Убедитесь, что используете AmneziaWG (не обычный WireGuard) и параметры обфускации совпадают на сервере и клиенте.

**Q: Российские сайты открываются через DE?**
A: Проверьте статус ipset: `ipset list ru_ips | head`. Если пусто — запустите `/usr/local/bin/update_ru_ips.sh`

**Q: Как добавить нового клиента?**
A: Через Web UI кнопкой "+ Добавить клиента"

**Q: Как сменить пароль админки?**
A: Отредактируйте `/opt/amnezia-vpn-manager/config/.env` и перезапустите сервис

## 📄 Лицензия

MIT License

## 🤝 Вклад

Pull requests приветствуются!

---

Создано с ❤️ для обхода блокировок
