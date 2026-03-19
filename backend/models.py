from datetime import datetime
from typing import Optional
from sqlmodel import SQLModel, Field


class Client(SQLModel, table=True):
    """Модель клиента VPN"""
    id: Optional[int] = Field(default=None, primary_key=True)
    name: str = Field(index=True)
    private_key: str
    public_key: str
    address: str = Field(unique=True)  # IP адрес в VPN сети (10.10.0.x)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    is_active: bool = Field(default=True)
    last_handshake: Optional[datetime] = None
    upload_bytes: int = Field(default=0)
    download_bytes: int = Field(default=0)


class ServerConfig(SQLModel):
    """Конфигурация сервера"""
    public_key: str
    endpoint: str
    port: int
    dns: str
    mtu: int
    # Параметры обфускации AmneziaWG
    jc: int
    jmin: int
    jmax: int
    s1: int
    s2: int
    h1: int
    h2: int
    h3: int
    h4: int


class ClientCreate(SQLModel):
    """Схема для создания клиента"""
    name: str


class ClientResponse(SQLModel):
    """Ответ с данными клиента"""
    id: int
    name: str
    address: str
    is_active: bool
    created_at: datetime
    last_handshake: Optional[datetime]
    upload_bytes: int
    download_bytes: int
    config: str  # Полный конфиг для клиента


class StatsResponse(SQLModel):
    """Статистика сервера"""
    total_clients: int
    active_clients: int
    total_upload: int
    total_download: int
    server_uptime: str


class UserLogin(SQLModel):
    """Данные для входа"""
    username: str
    password: str


class Token(SQLModel):
    """JWT токен"""
    access_token: str
    token_type: str = "bearer"
