# OTP Relay Monitor — monitor.py
# Runs as a separate monitor process/container.
# Two parallel tasks:
#   1. Phone watcher  — uses ARP checks for iPhone presence and writes
#                       phone_online / phone_offline events to the audit log
#   2. Alert forwarder — tails the audit log in real time and forwards only
#                        phone_online / phone_offline events to Telegram.
#
# SCH production model:
#   - monitor.py sends Telegram alerts for iPhone state changes only.
#   - Broader app/cluster alerts are handled by Prometheus Alertmanager.

import json
import logging
import os
import subprocess
import threading
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv
from prometheus_client import Counter, Gauge, Histogram, start_http_server

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")


def _resolve_runtime_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else BASE_DIR / path


# ── Config ────────────────────────────────────────────────────────────────────
DATA_DIR = _resolve_runtime_path(os.getenv("OTP_RELAY_DATA_DIR", "data"))
AUDIT_LOG_PATH = str(
    _resolve_runtime_path(
        os.getenv("AUDIT_LOG_PATH", str(DATA_DIR / "audit.log"))
    )
)

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
PHONE_IP = os.getenv("PHONE_IP", "")
PHONE_INTERFACE = os.getenv("PHONE_INTERFACE", "ens33")
PHONE_PING_INTERVAL = int(os.getenv("PHONE_PING_INTERVAL", "300"))
PHONE_OFFLINE_THRESHOLD = int(os.getenv("PHONE_OFFLINE_THRESHOLD", "2"))
PHONE_ARP_COUNT = int(os.getenv("PHONE_ARP_COUNT", "2"))
PHONE_ARP_TIMEOUT = int(os.getenv("PHONE_ARP_TIMEOUT", "2"))
MONITOR_METRICS_PORT = int(os.getenv("MONITOR_METRICS_PORT", "9101"))

# Prefer an explicit URL for Kubernetes, where Service/Ingress naming may differ.
_explicit_portal_url = os.getenv("PORTAL_URL", "").strip()
_server_hostname = os.getenv("SERVER_HOSTNAME", "").strip()
_server_ip = os.getenv("SERVER_IP", "").strip()
PORTAL_URL = (
    _explicit_portal_url or
    (f"https://{_server_hostname}" if _server_hostname else "") or
    (f"https://{_server_ip}" if _server_ip else "") or
    "https://srvotp26.init-db.lan"
)


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
logger = logging.getLogger("otp-monitor")


# ── Prometheus metrics ────────────────────────────────────────────────────────
OTP_IPHONE_PRESENT = Gauge(
    "otp_iphone_present",
    "Whether the monitored iPhone is currently reachable by ARP",
)
OTP_IPHONE_ABSENCE_SECONDS = Gauge(
    "otp_iphone_absence_seconds",
    "Current iPhone absence duration in seconds; zero while the phone is reachable",
)
OTP_IPHONE_ABSENCE_EVENTS_TOTAL = Counter(
    "otp_iphone_absence_events_total",
    "Total number of iPhone absence events detected by the monitor",
)
OTP_IPHONE_ABSENCE_DURATION_SECONDS = Histogram(
    "otp_iphone_absence_duration_seconds",
    "Duration in seconds of completed iPhone absence events",
)
OTP_MONITOR_ARP_LAST_SUCCESS_TIMESTAMP_SECONDS = Gauge(
    "otp_monitor_arp_last_success_timestamp_seconds",
    "Unix timestamp of the last successful ARP check",
)


# ── Audit log writer ──────────────────────────────────────────────────────────
def audit(event: str, detail: str = "", status: str = "info"):
    entry = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event,
        "token": "",
        "detail": detail,
        "status": status,
    }
    try:
        Path(AUDIT_LOG_PATH).parent.mkdir(parents=True, exist_ok=True)
        with open(AUDIT_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        logger.warning(f"Could not write audit log: {e}")

    level = {"info": logging.INFO, "warn": logging.WARNING, "error": logging.ERROR}.get(status, logging.INFO)
    logger.log(level, f"[{event}] {detail}")


# ── Telegram Bot API ───────────────────────────────────────────────────────────
def send_telegram(message: str):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        logger.warning("Telegram not configured — skipping alert")
        return

    try:
        payload = json.dumps({
            "chat_id": TELEGRAM_CHAT_ID,
            "text": message,
            "parse_mode": "Markdown",
            "disable_web_page_preview": True,
        }).encode("utf-8")

        request = urllib.request.Request(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read().decode(errors="replace")
            logger.info("Telegram alert sent — response: %s", body[:120])
    except Exception as e:
        logger.error("Telegram delivery failed: %s", e)


def dispatch(entry: dict):
    event = entry.get("event", "")
    if event == "phone_offline":
        icon = "🔴"
        title = "OTP Relay iPhone Offline"
    elif event == "phone_online":
        icon = "🟢"
        title = "OTP Relay iPhone Online"
    else:
        return

    message = (
        f"{icon} *{title}*\n"
        f"{entry.get('detail', '')}\n\n"
        f"🔗 {PORTAL_URL}/admin/log"
    )
    send_telegram(message)


# ── Log tailer ────────────────────────────────────────────────────────────────
def tail_audit_log():
    """
    Follows the audit log file from the end, like `tail -f`.

    SCH behavior: forward only phone_offline and phone_online events to Telegram.
    Other app/cluster alerts are handled by Prometheus Alertmanager.
    """
    log_path = Path(AUDIT_LOG_PATH)
    logger.info(f"Log tailer started — watching {log_path}")

    while not log_path.exists():
        time.sleep(5)

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        f.seek(0, 2)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.5)
                continue

            raw = line.strip()
            if not raw or "\x00" in raw:
                continue

            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue

            if entry.get("event") in {"phone_offline", "phone_online"}:
                dispatch(entry)


# ── Phone watcher ─────────────────────────────────────────────────────────────
def ping(ip: str) -> bool:
    """Use ARP instead of ICMP ping for iPhone presence detection."""
    try:
        result = subprocess.run(
            [
                "arping",
                "-c", str(PHONE_ARP_COUNT),
                "-w", str(PHONE_ARP_TIMEOUT),
                "-I", PHONE_INTERFACE,
                ip,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    except Exception as e:
        logger.error(f"arping execution error: {e}")
        return False


def watch_phone():
    OTP_IPHONE_PRESENT.set(0)
    OTP_IPHONE_ABSENCE_SECONDS.set(0)

    if not PHONE_IP:
        logger.warning("PHONE_IP not set — phone watcher disabled")
        return

    logger.info(
        f"Phone watcher started — target {PHONE_IP}, "
        f"interface {PHONE_INTERFACE}, "
        f"interval {PHONE_PING_INTERVAL}s, "
        f"threshold {PHONE_OFFLINE_THRESHOLD} missed pings, "
        f"arp_count {PHONE_ARP_COUNT}, "
        f"arp_timeout {PHONE_ARP_TIMEOUT}s"
    )

    if not os.path.exists(f"/sys/class/net/{PHONE_INTERFACE}"):
        logger.critical(f"Network interface {PHONE_INTERFACE} not found — phone watcher disabled")
        audit(
            "monitor_error",
            f"Interface {PHONE_INTERFACE} not found — check PHONE_INTERFACE / hostNetwork settings",
            "error",
        )
        return

    consecutive_failures = 0
    phone_online = True
    absence_started_at = None

    # Short delay before first check to let networking settle after start.
    time.sleep(30)

    while True:
        if ping(PHONE_IP):
            now_ts = time.time()
            OTP_MONITOR_ARP_LAST_SUCCESS_TIMESTAMP_SECONDS.set(now_ts)
            OTP_IPHONE_PRESENT.set(1)
            OTP_IPHONE_ABSENCE_SECONDS.set(0)

            if not phone_online:
                phone_online = True
                consecutive_failures = 0
                if absence_started_at is not None:
                    OTP_IPHONE_ABSENCE_DURATION_SECONDS.observe(max(0, now_ts - absence_started_at))
                    absence_started_at = None
                audit("phone_online", f"iPhone {PHONE_IP} is reachable again", "info")
                logger.info(f"Phone {PHONE_IP} back online")
            else:
                consecutive_failures = 0
        else:
            consecutive_failures += 1
            if consecutive_failures <= PHONE_OFFLINE_THRESHOLD:
                logger.info(f"ARP failed ({consecutive_failures}/{PHONE_OFFLINE_THRESHOLD})")

            if phone_online and consecutive_failures >= PHONE_OFFLINE_THRESHOLD:
                phone_online = False
                absence_started_at = time.time()
                OTP_IPHONE_PRESENT.set(0)
                OTP_IPHONE_ABSENCE_SECONDS.set(0)
                OTP_IPHONE_ABSENCE_EVENTS_TOTAL.inc()
                audit(
                    "phone_offline",
                    f"iPhone {PHONE_IP} unreachable after {PHONE_OFFLINE_THRESHOLD} consecutive ARP checks",
                    "error",
                )
                logger.error(f"Phone {PHONE_IP} declared offline")
            elif not phone_online and absence_started_at is not None:
                OTP_IPHONE_PRESENT.set(0)
                OTP_IPHONE_ABSENCE_SECONDS.set(max(0, time.time() - absence_started_at))

        time.sleep(PHONE_PING_INTERVAL)


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    logger.info("OTP Monitor starting")
    start_http_server(MONITOR_METRICS_PORT)
    logger.info("Prometheus metrics server listening on port %s", MONITOR_METRICS_PORT)

    audit(
        "monitor_start",
        f"telegram_configured={bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)} "
        f"phone_ip={PHONE_IP or 'not set'} "
        f"interface={PHONE_INTERFACE} ping_interval={PHONE_PING_INTERVAL}s "
        f"arp_count={PHONE_ARP_COUNT} arp_timeout={PHONE_ARP_TIMEOUT}s",
        "info",
    )

    phone_thread = threading.Thread(target=watch_phone, daemon=True)
    phone_thread.start()

    tail_audit_log()
