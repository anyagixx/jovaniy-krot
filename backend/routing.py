import subprocess
import httpx
from pathlib import Path
from typing import List, Optional


class RoutingManager:
    """Менеджер для управления маршрутизацией и split-tunneling"""
    
    IPSET_NAME = "ru_ips"
    ROUTING_TABLE = 100
    FWMARK = 255
    
    def __init__(self):
        self.update_script = Path("/usr/local/bin/update_ru_ips.sh")
    
    def update_ru_ipset(self) -> bool:
        """Обновление списка IP-адресов России"""
        try:
            if self.update_script.exists():
                subprocess.run(["bash", str(self.update_script)], check=True)
                return True
        except Exception as e:
            print(f"Error updating ipset: {e}")
        return False
    
    def get_ipset_stats(self) -> dict:
        """Получение статистики ipset"""
        try:
            result = subprocess.run(
                ["ipset", "list", self.IPSET_NAME],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                lines = result.stdout.split('\n')
                count = 0
                for line in lines:
                    if line.startswith("Number of entries:"):
                        count = int(line.split(':')[1].strip())
                return {"name": self.IPSET_NAME, "entries": count, "status": "active"}
        except Exception:
            pass
        return {"name": self.IPSET_NAME, "entries": 0, "status": "inactive"}
    
    def get_routing_rules(self) -> List[dict]:
        """Получение правил маршрутизации"""
        rules = []
        try:
            # IP rules
            result = subprocess.run(
                ["ip", "rule", "list"],
                capture_output=True, text=True
            )
            for line in result.stdout.split('\n'):
                if str(self.FWMARK) in line or str(self.ROUTING_TABLE) in line:
                    rules.append({"type": "rule", "value": line})
            
            # IP routes in custom table
            result = subprocess.run(
                ["ip", "route", "list", "table", str(self.ROUTING_TABLE)],
                capture_output=True, text=True
            )
            for line in result.stdout.split('\n'):
                if line.strip():
                    rules.append({"type": "route", "value": line})
        
        except Exception:
            pass
        
        return rules
    
    def check_tunnel_status(self) -> dict:
        """Проверка статуса туннеля до DE-сервера"""
        try:
            # Проверяем интерфейс awg0
            result = subprocess.run(
                ["ip", "link", "show", "awg0"],
                capture_output=True, text=True
            )
            if result.returncode == 0 and "UP" in result.stdout:
                # Пингуем через туннель
                result = subprocess.run(
                    ["ping", "-c", "1", "-W", "2", "-I", "awg0", "8.8.8.8"],
                    capture_output=True, text=True
                )
                return {
                    "interface": "awg0",
                    "status": "up" if result.returncode == 0 else "no_connectivity"
                }
        except Exception:
            pass
        return {"interface": "awg0", "status": "down"}
    
    def setup_split_tunnel(self, interface: str = "awg-client") -> bool:
        """Настройка split-tunneling"""
        try:
            commands = [
                # Создаем ipset если не существует
                f"ipset create {self.IPSET_NAME} hash:net 2>/dev/null || true",
                # Добавляем локальные сети
                f"ipset add {self.IPSET_NAME} 10.0.0.0/8 2>/dev/null || true",
                f"ipset add {self.IPSET_NAME} 192.168.0.0/16 2>/dev/null || true",
                f"ipset add {self.IPSET_NAME} 172.16.0.0/12 2>/dev/null || true",
                # Правило маршрутизации
                f"ip rule add fwmark {self.FWMARK} lookup {self.ROUTING_TABLE} 2>/dev/null || true",
                # Маршрут по умолчанию через туннель
                f"ip route add default dev awg0 table {self.ROUTING_TABLE} 2>/dev/null || true",
                # NAT
                f"iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null || true",
                # Маркировка пакетов
                f"iptables -t mangle -A PREROUTING -i {interface} -m set ! --match-set {self.IPSET_NAME} dst -j MARK --set-mark {self.FWMARK} 2>/dev/null || true",
            ]
            
            for cmd in commands:
                subprocess.run(cmd, shell=True, capture_output=True)
            
            return True
        except Exception as e:
            print(f"Error setting up split tunnel: {e}")
            return False
    
    def get_connection_stats(self) -> dict:
        """Получение общей статистики соединений"""
        stats = {
            "tunnel": self.check_tunnel_status(),
            "ipset": self.get_ipset_stats(),
            "rules_count": len(self.get_routing_rules())
        }
        return stats


# Глобальный экземпляр
routing_manager = RoutingManager()
