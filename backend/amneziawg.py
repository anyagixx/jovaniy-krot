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
        
        # Параметры обфускации по умолчанию
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
        """Генерация пары ключей (private, public)"""
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
            "https://api4.my-ip.io/ip"
        ]
        for endpoint in endpoints:
            try:
                return httpx.get(endpoint, timeout=5).text.strip()
            except Exception:
                continue
        return None
    
    def get_next_client_ip(self) -> str:
        """Получение следующего свободного IP для клиента"""
        used_ips = set()
        
        if self.server_config.exists():
            content = self.server_config.read_text()
            # Ищем все AllowedIPs в секциях [Peer]
            matches = re.findall(r'AllowedIPs\s*=\s*10\.10\.0\.(\d+)/32', content)
            for m in matches:
                used_ips.add(int(m))
        
        # Ищем свободный IP (начиная с 2, т.к. 1 - сервер)
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
        
        config = f"""[Interface]
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
        return config
    
    def add_peer(self, public_key: str, address: str) -> bool:
        """Добавление пира в конфиг сервера"""
        try:
            # Добавляем в конфиг файл
            peer_config = f"""
[Peer]
# Client: auto-added
PublicKey = {public_key}
AllowedIPs = {address}/32
"""
            with open(self.server_config, "a") as f:
                f.write(peer_config)
            
            # Добавляем в runtime через wg syncconf (быстрее без перезапуска)
            try:
                # Создаем временный файл с новым пиром
                temp_config = f"[Peer]\nPublicKey = {public_key}\nAllowedIPs = {address}/32\n"
                subprocess.run(
                    ["awg", "set", self.server_interface, "peer", public_key, "allowed-ips", f"{address}/32"],
                    capture_output=True, check=True
                )
            except subprocess.CalledProcessError:
                # Если sync не сработал, перезапускаем сервис
                subprocess.run(
                    ["systemctl", "restart", f"awg-quick@{self.server_interface}"],
                    capture_output=True, check=True
                )
            
            return True
        except Exception as e:
            print(f"Error adding peer: {e}")
            return False
    
    def remove_peer(self, public_key: str) -> bool:
        """Удаление пира из конфига сервера"""
        try:
            # Удаляем из runtime
            subprocess.run(
                ["awg", "set", self.server_interface, "peer", public_key, "remove"],
                capture_output=True
            )
            
            # Удаляем из конфиг файла
            if self.server_config.exists():
                content = self.server_config.read_text()
                # Ищем и удаляем секцию пира
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
            result = subprocess.run(
                ["awg", "show", self.server_interface, "latest-handshakes", "transfer"],
                capture_output=True, text=True, check=True
            )
            
            # Парсим вывод
            lines = result.stdout.strip().split('\n')
            current_peer = None
            
            for line in lines:
                if line.startswith("peer:"):
                    current_peer = line.split()[1]
                    stats[current_peer] = {
                        "last_handshake": None,
                        "upload": 0,
                        "download": 0
                    }
                elif "latest handshake" in line and current_peer:
                    # Парсим время handshake
                    pass  # Сложно парсить, пропускаем
                elif "transfer" in line and current_peer:
                    # Парсим transfer: XX.XXB received, XX.XXB sent
                    match = re.search(r'([\d.]+)([KMGT]?B) received,\s*([\d.]+)([KMGT]?B) sent', line)
                    if match:
                        stats[current_peer]["download"] = self._parse_bytes(match.group(1), match.group(2))
                        stats[current_peer]["upload"] = self._parse_bytes(match.group(3), match.group(4))
            
            # Альтернативный способ - через awg show dump
            result = subprocess.run(
                ["awg", "show", self.server_interface, "dump"],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                for line in result.stdout.strip().split('\n')[1:]:  # Пропускаем заголовок
                    parts = line.split('\t')
                    if len(parts) >= 8:
                        peer_key = parts[0]
                        if peer_key not in stats:
                            stats[peer_key] = {"last_handshake": None, "upload": 0, "download": 0}
                        stats[peer_key]["upload"] = int(parts[6]) if parts[6].isdigit() else 0
                        stats[peer_key]["download"] = int(parts[7]) if parts[7].isdigit() else 0
                        
                        # Handshake time
                        handshake = int(parts[4]) if parts[4].isdigit() else 0
                        if handshake > 0:
                            stats[peer_key]["last_handshake"] = datetime.fromtimestamp(handshake)
            
        except Exception as e:
            print(f"Error getting stats: {e}")
        
        return stats
    
    def _parse_bytes(self, value: str, unit: str) -> int:
        """Конвертация человекочитаемых байтов в число"""
        multipliers = {'B': 1, 'KB': 1024, 'MB': 1024**2, 'GB': 1024**3, 'TB': 1024**4}
        return int(float(value) * multipliers.get(unit, 1))
    
    def is_service_running(self) -> bool:
        """Проверка, запущен ли сервис"""
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


# Глобальный экземпляр
wg_manager = AmneziaWGManager()
