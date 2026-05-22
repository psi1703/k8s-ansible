"""Monitor process entrypoint."""

import threading

from prometheus_client import start_http_server

from .alerts import dispatch
from .audit_tail import audit, tail_audit_log
from .config import (
    MONITOR_METRICS_PORT,
    PHONE_ARP_COUNT,
    PHONE_ARP_TIMEOUT,
    PHONE_INTERFACE,
    PHONE_IP,
    PHONE_PING_INTERVAL,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
)
from .logging_config import logger
from .phone import watch_phone


def main():
    logger.info("OTP Monitor starting")
    start_http_server(MONITOR_METRICS_PORT)
    logger.info("Prometheus metrics server listening on port %s", MONITOR_METRICS_PORT)

    audit(
        "monitor_start",
        f"telegram_configured={bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)} "
        f"phone_ip={PHONE_IP or 'not set'} "
        f"interface={PHONE_INTERFACE or 'not set'} ping_interval={PHONE_PING_INTERVAL}s "
        f"arp_count={PHONE_ARP_COUNT} arp_timeout={PHONE_ARP_TIMEOUT}s",
        "info",
    )

    phone_thread = threading.Thread(target=watch_phone, daemon=True)
    phone_thread.start()

    tail_audit_log(dispatch)
