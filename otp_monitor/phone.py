"""ARP-based phone presence checks."""

import os
import subprocess
import time

from .audit_tail import audit
from .config import (
    PHONE_ARP_COUNT,
    PHONE_ARP_TIMEOUT,
    PHONE_INTERFACE,
    PHONE_IP,
    PHONE_OFFLINE_THRESHOLD,
    PHONE_PING_INTERVAL,
)
from .logging_config import logger
from .metrics import (
    OTP_IPHONE_ABSENCE_DURATION_SECONDS,
    OTP_IPHONE_ABSENCE_EVENTS_TOTAL,
    OTP_IPHONE_ABSENCE_SECONDS,
    OTP_IPHONE_PRESENT,
    OTP_MONITOR_ARP_LAST_SUCCESS_TIMESTAMP_SECONDS,
)


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
        logger.error("arping execution error: %s", e)
        return False


def watch_phone():
    OTP_IPHONE_PRESENT.set(0)
    OTP_IPHONE_ABSENCE_SECONDS.set(0)

    if not PHONE_IP:
        logger.warning("PHONE_IP not set — phone watcher disabled")
        return
    if not PHONE_INTERFACE:
        logger.critical("PHONE_INTERFACE not set — phone watcher disabled")
        audit("monitor_error", "PHONE_INTERFACE not set — configure the installer .env file", "error")
        return

    logger.info(
        "Phone watcher started — target %s, interface %s, interval %ss, threshold %s missed pings, arp_count %s, arp_timeout %ss",
        PHONE_IP,
        PHONE_INTERFACE,
        PHONE_PING_INTERVAL,
        PHONE_OFFLINE_THRESHOLD,
        PHONE_ARP_COUNT,
        PHONE_ARP_TIMEOUT,
    )

    if not os.path.exists(f"/sys/class/net/{PHONE_INTERFACE}"):
        logger.critical("Network interface %s not found — phone watcher disabled", PHONE_INTERFACE)
        audit(
            "monitor_error",
            f"Interface {PHONE_INTERFACE} not found — check PHONE_INTERFACE / hostNetwork settings",
            "error",
        )
        return

    consecutive_failures = 0
    phone_online = True
    absence_started_at = None

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
                logger.info("Phone %s back online", PHONE_IP)
            else:
                consecutive_failures = 0
        else:
            consecutive_failures += 1
            if consecutive_failures <= PHONE_OFFLINE_THRESHOLD:
                logger.info("ARP failed (%s/%s)", consecutive_failures, PHONE_OFFLINE_THRESHOLD)

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
                logger.error("Phone %s declared offline", PHONE_IP)
            elif not phone_online and absence_started_at is not None:
                OTP_IPHONE_PRESENT.set(0)
                OTP_IPHONE_ABSENCE_SECONDS.set(max(0, time.time() - absence_started_at))

        time.sleep(PHONE_PING_INTERVAL)
