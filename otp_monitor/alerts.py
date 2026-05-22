"""Telegram alert delivery for monitor events."""

import json
import urllib.request

from .config import PORTAL_URL, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
from .logging_config import logger


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

    portal_line = f"\n\n🔗 {PORTAL_URL}/admin/log" if PORTAL_URL else ""
    message = f"{icon} *{title}*\n{entry.get('detail', '')}{portal_line}"
    send_telegram(message)
