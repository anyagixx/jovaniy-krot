import subprocess
import os
import re
from pathlib import Path
from typing import Optional, Tuple, List
from datetime import datetime


class AmneziaWGManager:
    """Менеджер для работы с AmneziaWG"""
    
    def __init__(self, config_dir: str = "/etc/amnezia/amneziawg"):
        self.config_dir = Path(config_dir)
        self.server_interface = "awg-client"
        self.server_config = self.config_dir / f"{self.server_interface}.conf"
        
        self.obfuscation = {
            "jc": 120,
            "jmin": 50,
            "jmax": 1000,
            "s1": 111,
            "s2": 222,
            "h1": 1,
            "h2": 2,
            "h3": 3,
            "h4": 4,
        }
    
    def generate_keypair(self) -> Tuple[str, str]:
        """Генерация пары ключей"""
        private = subprocess.run(
            ["awg", "genkey"],
            capture_output=True, text=True, check=True
        ).stdout.strip()
        
        public = subprocess.run(
            ["awg", "pubkey"],
            input=private, capture_output=True, text=True, check=True
        ).stdout.strip()
        
        return private, public
    
    def get_server_public_key(self) -> Optional[str]:
        """Получение публичного ключа сервера"""
        try:
            key_file = self.config_dir / "vpn_pub"
            if key_file.exists():
                return key_file.read_text().strip()
        except Exception:
            pass
        return None
    
    def get_server_endpoint(self) -> Optional[str]:
        """Получение внешнего IP сервера"""
        import httpx
        endpoints = [
            "https://api.ipify.org",
            "https://ifconfig.me",
        ]
        for ep in endpoints:
            try:
                return httpx.get(ep, timeout=5).text.strip()
            except Exception:
                continue
        return None
    
    def get_next_client_ip(self) -> str:
        """Получение следующего свободного IP"""
        used_ips = set()
        
        if self.server_config.exists():
            content = self.server_config.read_text()
            matches = re.findall(r'AllowedIPs\s*=\s*10\.10\.0\.(\d+)/32', content)
            for m in matches:
                used_ips.add(int(m))
        
        for i in range(2, 255):
            if i not in used_ips:
                return f"10.10.0.{i}"
        
        raise Exception("No available IP addresses")
    
    def create_client_config(
        self, 
        name: str,
        private_key: str,
        public_key: str,
        address: str
    ) -> str:
        """Создание конфига для клиента"""
        server_pub = self.get_server_public_key()
        endpoint = self.get_server_endpoint()
        
        if not server_pub or not endpoint:
            raise Exception("Cannot get server public key or endpoint")
        
        return f"""[Interface]
PrivateKey = {private_key}
Address = {address}/32
DNS = 8.8.8.8, 1.1.1.1
MTU = 1360
Jc = {self.obfuscation['jc']}
Jmin = {self.obfuscation['jmin']}
Jmax = {self.obfuscation['jmax']}
S1 = {self.obfuscation['s1']}
S2 = {self.obfuscation['s2']}
H1 = {self.obfuscation['h1']}
H2 = {self.obfuscation['h2']}
H3 = {self.obfuscation['h3']}
H4 = {self.obfuscation['h4']}

[Peer]
PublicKey = {server_pub}
Endpoint = {endpoint}:51821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""
    
    def add_peer(self, public_key: str, address: str) -> bool:
        """Добавление пира"""
        try:
            peer_config = f"""

[Peer]
PublicKey = {public_key}
AllowedIPs = {address}/32
"""
            with open(self.server_config, "a") as f:
                f.write(peer_config)
            
            try:
                subprocess.run(
                    ["awg", "set", self.server_interface, "peer", public_key, "allowed-ips", f"{address}/32"],
                    capture_output=True, check=True, timeout=5
                )
            except Exception:
                subprocess.run(
                    ["systemctl", "restart", f"awg-quick@{self.server_interface}"],
                    capture_output=True, check=True
                )
            
            return True
        except Exception as e:
            print(f"Error adding peer: {e}")
            return False
    
    def remove_peer(self, public_key: str) -> bool:
        """Удаление пира"""
        try:
            subprocess.run(
                ["awg", "set", self.server_interface, "peer", public_key, "remove"],
                capture_output=True, timeout=5
            )
            
            if self.server_config.exists():
                content = self.server_config.read_text()
                pattern = rf'\n\[Peer\]\nPublicKey\s*=\s*{re.escape(public_key)}\nAllowedIPs\s*=\s*[^\n]+\n'
                new_content = re.sub(pattern, '', content)
                self.server_config.write_text(new_content)
            
            return True
        except Exception as e:
            print(f"Error removing peer: {e}")
            return False
    
    def get_peer_stats(self) -> dict:
        """Получение статистики пиров"""
        stats = {}
        try:
            # Используем awg show dump для получения всех данных
            result = subprocess.run(
                ["awg", "show", self.server_interface, "dump"],
                capture_output=True, text=True, timeout=10
            )
            
            if result.returncode != 0:
                return stats
            
            # Парсим вывод dump
            # Формат: private-key public-key listen-port fwmark
            # Для каждого пира: public-key preshared-key endpoint allowed-ips latest-handshake transfer-rx transfer-tx
            
            lines = result.stdout.strip().split('\n')
            if len(lines) < 2:
                return stats
            
            # Первая строка - интерфейс, пропускаем
            for line in lines[1:]:
                parts = line.split('\t')
                if len(parts) >= 8:
                    peer_key = parts[0]
                    handshake = int(parts[4]) if parts[4].isdigit() else 0
                    rx_bytes = int(parts[5]) if parts[5].isdigit() else 0
                    tx_bytes = int(parts[6]) if parts[6].isdigit() else 0
                    
                    stats[peer_key] = {
                        "last_handshake": datetime.fromtimestamp(handshake) if handshake > 0 else None,
                        "upload": tx_bytes,  # tx = отправлено клиентом = upload
                        "download": rx_bytes  # rx = получено клиентом = download
                    }
                    
        except Exception as e:
            print(f"Error getting stats: {e}")
        
        return stats
    
    def is_service_running(self) -> bool:
        """Проверка статуса сервиса"""
        try:
            result = subprocess.run(
                ["systemctl", "is-active", f"awg-quick@{self.server_interface}"],
                capture_output=True, text=True
            )
            return result.stdout.strip() == "active"
        except Exception:
            return False
    
    def restart_service(self) -> bool:
        """Перезапуск сервиса"""
        try:
            subprocess.run(
                ["systemctl", "restart", f"awg-quick@{self.server_interface}"],
                capture_output=True, check=True
            )
            return True
        except Exception:
            return False


wg_manager = AmneziaWGManager()
