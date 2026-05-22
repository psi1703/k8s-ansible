"""Configuration for the OTP Relay monitor.

All deployment-specific values come from environment variables. The installer
creates and maintains the root .env file, then renders these values into the
Kubernetes ConfigMap/Secret used by the monitor container.
"""

import os
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")


def _resolve_runtime_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else BASE_DIR / path


DATA_DIR = _resolve_runtime_path(os.getenv("OTP_RELAY_DATA_DIR", "data"))
AUDIT_LOG_PATH = str(_resolve_runtime_path(os.getenv("AUDIT_LOG_PATH", str(DATA_DIR / "audit.log"))))

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
PHONE_IP = os.getenv("PHONE_IP", "")
PHONE_INTERFACE = os.getenv("PHONE_INTERFACE", "")
PHONE_PING_INTERVAL = int(os.getenv("PHONE_PING_INTERVAL", "300"))
PHONE_OFFLINE_THRESHOLD = int(os.getenv("PHONE_OFFLINE_THRESHOLD", "2"))
PHONE_ARP_COUNT = int(os.getenv("PHONE_ARP_COUNT", "2"))
PHONE_ARP_TIMEOUT = int(os.getenv("PHONE_ARP_TIMEOUT", "2"))
MONITOR_METRICS_PORT = int(os.getenv("MONITOR_METRICS_PORT", "9101"))
PORTAL_URL = os.getenv("PORTAL_URL", "").strip()
