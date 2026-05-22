"""Audit-log writing and tailing for monitor events."""

import json
import logging
import time
from datetime import datetime, timezone
from pathlib import Path

from .config import AUDIT_LOG_PATH
from .logging_config import logger


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
        logger.warning("Could not write audit log: %s", e)

    level = {"info": logging.INFO, "warn": logging.WARNING, "error": logging.ERROR}.get(status, logging.INFO)
    logger.log(level, "[%s] %s", event, detail)


def tail_audit_log(dispatch):
    """Follow the audit log and dispatch phone state events."""
    log_path = Path(AUDIT_LOG_PATH)
    logger.info("Log tailer started — watching %s", log_path)

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
