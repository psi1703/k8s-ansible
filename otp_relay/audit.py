import json
import logging
from collections import deque
from pathlib import Path
from typing import Optional

from otp_relay.config import AUDIT_LOG_PATH, _utcnow_naive, logger


def audit(event: str, token: Optional[str] = None, detail: str = "", status: str = "info") -> None:
    entry = {
        "ts": _utcnow_naive().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event,
        "token": token or "",
        "detail": detail,
        "status": status,
    }
    try:
        audit_path = Path(AUDIT_LOG_PATH)
        audit_path.parent.mkdir(parents=True, exist_ok=True)
        with audit_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
    except Exception as exc:
        logger.warning("Could not write audit log: %s", exc)

    level = {"info": logging.INFO, "warn": logging.WARNING, "error": logging.ERROR}.get(status, logging.INFO)
    logger.log(level, "[%s] token=%s  %s", event, token or "-", detail)


def read_audit_log(limit: int = 200) -> list:
    """Read recent audit entries without letting one corrupt line hide the log.

    The audit file is append-only and can be shared by the app and monitor over
    PVC/NFS. If a pod/node dies while a write is in progress, the file can
    contain a blank, NUL-filled, or otherwise malformed line. Admin log viewing
    must skip those bad lines and continue returning valid audit entries.
    """
    limit = max(1, min(int(limit or 200), 2000))
    skipped = 0
    entries = []

    try:
        with Path(AUDIT_LOG_PATH).open("r", encoding="utf-8", errors="replace") as handle:
            tail = deque(handle, maxlen=limit)
    except FileNotFoundError:
        return []
    except Exception as exc:
        logger.warning("Could not read audit log: %s", exc)
        return []

    for line_no, line in enumerate(tail, start=1):
        raw = line.strip()
        if not raw:
            skipped += 1
            continue

        # NUL-filled lines can appear after interrupted writes on shared
        # storage. They are never valid audit entries.
        if "\x00" in raw:
            skipped += 1
            continue

        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            skipped += 1
            continue

        if isinstance(entry, dict):
            entries.append(entry)
        else:
            skipped += 1

    if skipped:
        logger.warning("Skipped %s malformed audit log line(s)", skipped)

    return list(reversed(entries))
