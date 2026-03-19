FROM python:3.11-slim

LABEL maintainer="AmneziaVPN Manager"
LABEL description="Web UI for managing AmneziaWG VPN with split-tunneling"

# Установка системных зависимостей
RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    ipset \
    iptables \
    qrencode \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Рабочая директория
WORKDIR /app

# Копирование зависимостей
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копирование приложения
COPY backend/ ./backend/
COPY frontend/ ./frontend/

# Создание директории для данных
RUN mkdir -p /app/data /etc/amnezia/amneziawg

# Переменные окружения
ENV PYTHONUNBUFFERED=1
ENV DATABASE_URL=sqlite:///./data/vpn_manager.db

# Порт
EXPOSE 8000

# Запуск
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
