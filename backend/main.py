import io
import os
from pathlib import Path
from datetime import datetime
from typing import List, Optional

import qrcode
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.responses import StreamingResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from sqlmodel import Session, select

from database import init_db, get_db
from models import (
    Client, ClientCreate, ClientResponse, StatsResponse,
    ServerConfig, UserLogin, Token
)
from amneziawg import wg_manager
from routing import routing_manager

# Конфигурация
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "changeme")
SECRET_KEY = os.getenv("SECRET_KEY", "your-secret-key-change-in-production")

app = FastAPI(
    title="AmneziaVPN Manager",
    description="Web UI для управления AmneziaWG VPN с split-tunneling",
    version="1.0.3"
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Security
security = HTTPBearer()


def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Простая проверка токена"""
    from jose import jwt
    try:
        payload = jwt.decode(credentials.credentials, SECRET_KEY, algorithms=["HS256"])
        if payload.get("sub") != ADMIN_USERNAME:
            raise HTTPException(status_code=401, detail="Invalid token")
        return payload
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")


@app.on_event("startup")
def on_startup():
    """Инициализация при запуске"""
    init_db()
    routing_manager.update_ru_ipset()


# ==================== AUTH ====================

@app.post("/api/auth/login", response_model=Token)
def login(data: UserLogin):
    """Авторизация"""
    from jose import jwt
    if data.username != ADMIN_USERNAME or data.password != ADMIN_PASSWORD:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    
    token = jwt.encode(
        {"sub": data.username, "exp": datetime.utcnow().timestamp() + 86400 * 7},
        SECRET_KEY,
        algorithm="HS256"
    )
    return Token(access_token=token)


# ==================== CLIENTS ====================

@app.get("/api/clients", response_model=List[ClientResponse])
def list_clients(
    db: Session = Depends(get_db),
    _: dict = Depends(verify_token)
):
    """Получение списка всех клиентов"""
    clients = db.exec(select(Client)).all()
    
    # Получаем актуальную статистику
    stats = wg_manager.get_peer_stats()
    
    result = []
    for client in clients:
        peer_stats = stats.get(client.public_key, {})
        
        # Обновляем статистику в базе
        if peer_stats.get("upload", 0) > client.upload_bytes:
            client.upload_bytes = peer_stats["upload"]
            client.download_bytes = peer_stats["download"]
            client.last_handshake = peer_stats.get("last_handshake")
            db.add(client)
        
        # Генерируем конфиг
        config = wg_manager.create_client_config(
            client.name,
            client.private_key,
            client.public_key,
            client.address
        )
        
        result.append(ClientResponse(
            id=client.id,
            name=client.name,
            address=client.address,
            is_active=client.is_active,
            created_at=client.created_at,
            last_handshake=client.last_handshake,
            upload_bytes=client.upload_bytes,
            download_bytes=client.download_bytes,
            config=config
        ))
    
    db.commit()
    return result


@app.post("/api/clients", response_model=ClientResponse, status_code=201)
def create_client(
    data: ClientCreate,
    db: Session = Depends(get_db),
    _: dict = Depends(verify_token)
):
    """Создание нового клиента"""
    # Проверяем имя на уникальность
    existing = db.exec(select(Client).where(Client.name == data.name)).first()
    if existing:
        raise HTTPException(status_code=400, detail="Client with this name already exists")
    
    # Генерируем ключи
    private_key, public_key = wg_manager.generate_keypair()
    
    # Получаем следующий IP
    address = wg_manager.get_next_client_ip()
    
    # Добавляем пир в AmneziaWG
    if not wg_manager.add_peer(public_key, address):
        raise HTTPException(status_code=500, detail="Failed to add peer to WireGuard")
    
    # Создаем клиента в базе
    client = Client(
        name=data.name,
        private_key=private_key,
        public_key=public_key,
        address=address
    )
    db.add(client)
    db.commit()
    db.refresh(client)
    
    # Генерируем конфиг
    config = wg_manager.create_client_config(
        client.name,
        client.private_key,
        client.public_key,
        client.address
    )
    
    return ClientResponse(
        id=client.id,
        name=client.name,
        address=client.address,
        is_active=client.is_active,
        created_at=client.created_at,
        last_handshake=client.last_handshake,
        upload_bytes=client.upload_bytes,
        download_bytes=client.download_bytes,
        config=config
    )


@app.delete("/api/clients/{client_id}")
def delete_client(
    client_id: int,
    db: Session = Depends(get_db),
    _: dict = Depends(verify_token)
):
    """Удаление клиента"""
    client = db.get(Client, client_id)
    if not client:
        raise HTTPException(status_code=404, detail="Client not found")
    
    # Удаляем пир из AmneziaWG
    wg_manager.remove_peer(client.public_key)
    
    # Удаляем из базы
    db.delete(client)
    db.commit()
    
    return {"status": "deleted"}


@app.get("/api/clients/{client_id}/qr")
def get_client_qr(
    client_id: int,
    db: Session = Depends(get_db),
    _: dict = Depends(verify_token)
):
    """Получение QR-кода для клиента"""
    client = db.get(Client, client_id)
    if not client:
        raise HTTPException(status_code=404, detail="Client not found")
    
    config = wg_manager.create_client_config(
        client.name,
        client.private_key,
        client.public_key,
        client.address
    )
    
    # Генерируем QR-код
    qr = qrcode.QRCode(version=1, box_size=10, border=5)
    qr.add_data(config)
    qr.make(fit=True)
    
    img = qr.make_image(fill_color="black", back_color="white")
    
    # Возвращаем как PNG
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    
    return StreamingResponse(buf, media_type="image/png")


@app.get("/api/clients/{client_id}/config")
def get_client_config(
    client_id: int,
    db: Session = Depends(get_db),
    _: dict = Depends(verify_token)
):
    """Скачивание конфига клиента"""
    client = db.get(Client, client_id)
    if not client:
        raise HTTPException(status_code=404, detail="Client not found")
    
    config = wg_manager.create_client_config(
        client.name,
        client.private_key,
        client.public_key,
        client.address
    )
    
    return StreamingResponse(
        iter([config]),
        media_type="text/plain",
        headers={
            "Content-Disposition": f"attachment; filename={client.name}.conf"
        }
    )


@app.post("/api/clients/{client_id}/toggle")
def toggle_client(
    client_id: int,
    db: Session = Depends(get_db),
    _: dict = Depends(verify_token)
):
    """Включение/выключение клиента"""
    client = db.get(Client, client_id)
    if not client:
        raise HTTPException(status_code=404, detail="Client not found")
    
    client.is_active = not client.is_active
    
    if client.is_active:
        # Добавляем пир обратно
        wg_manager.add_peer(client.public_key, client.address)
    else:
        # Удаляем пир
        wg_manager.remove_peer(client.public_key)
    
    db.add(client)
    db.commit()
    
    return {"is_active": client.is_active}


# ==================== STATS ====================

@app.get("/api/stats", response_model=StatsResponse)
def get_stats(
    db: Session = Depends(get_db),
    _: dict = Depends(verify_token)
):
    """Получение общей статистики"""
    clients = db.exec(select(Client)).all()
    
    total_upload = sum(c.upload_bytes for c in clients)
    total_download = sum(c.download_bytes for c in clients)
    active_count = sum(1 for c in clients if c.is_active)
    
    # Uptime
    try:
        import subprocess
        result = subprocess.run(["uptime", "-p"], capture_output=True, text=True)
        uptime = result.stdout.strip().replace("up ", "")
    except Exception:
        uptime = "unknown"
    
    return StatsResponse(
        total_clients=len(clients),
        active_clients=active_count,
        total_upload=total_upload,
        total_download=total_download,
        server_uptime=uptime
    )


@app.get("/api/server/config")
def get_server_config(_: dict = Depends(verify_token)):
    """Получение конфигурации сервера"""
    return ServerConfig(
        public_key=wg_manager.get_server_public_key() or "unknown",
        endpoint=wg_manager.get_server_endpoint() or "unknown",
        port=51821,
        dns="8.8.8.8, 1.1.1.1",
        mtu=1360,
        **wg_manager.obfuscation
    )


@app.get("/api/routing/status")
def get_routing_status(_: dict = Depends(verify_token)):
    """Получение статуса маршрутизации"""
    return routing_manager.get_connection_stats()


@app.post("/api/routing/update-ips")
def update_ru_ips(_: dict = Depends(verify_token)):
    """Обновление списка IP России"""
    success = routing_manager.update_ru_ipset()
    if success:
        return {"status": "updated"}
    raise HTTPException(status_code=500, detail="Failed to update IP list")


@app.post("/api/server/restart")
def restart_server(_: dict = Depends(verify_token)):
    """Перезапуск VPN сервера"""
    if wg_manager.restart_service():
        return {"status": "restarted"}
    raise HTTPException(status_code=500, detail="Failed to restart server")


# ==================== STATIC FILES ====================

# Монтируем статику для фронтенда
frontend_path = Path(__file__).parent / "frontend"
if frontend_path.exists():
    app.mount("/static", StaticFiles(directory=str(frontend_path)), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    """Главная страница"""
    index_file = frontend_path / "index.html"
    if index_file.exists():
        return HTMLResponse(content=index_file.read_text())
    return HTMLResponse(content="<h1>AmneziaVPN Manager</h1><p>Frontend not found</p>")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
