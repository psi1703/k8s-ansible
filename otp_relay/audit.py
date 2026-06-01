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


def _parse_audit_line(line: str) -> Optional[dict]:
    """Parse one audit line.

    Shared storage can occasionally leave NUL bytes in otherwise valid JSON
    lines. Remove NUL bytes before parsing, but continue skipping truly blank
    or malformed lines.
    """
    raw = line.replace("\x00", "").strip()
    if not raw:
        return None

    try:
        entry = json.loads(raw)
    except json.JSONDecodeError:
        return None

    return entry if isinstance(entry, dict) else None


def read_audit_log(limit: int = 200) -> list:
    """Read recent audit entries, newest first.

    The audit file is append-only and can be shared by the app and monitor over
    PVC/NFS. If a pod/node dies while a write is in progress, the file can
    contain a blank, NUL-filled, or otherwise malformed line. Admin log viewing
    must skip bad lines and continue returning valid audit entries.
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

    for line in tail:
        entry = _parse_audit_line(line)
        if entry is None:
            skipped += 1
            continue
        entries.append(entry)

    if skipped:
        logger.warning("Skipped %s malformed audit log line(s)", skipped)

    return list(reversed(entries))


def count_audit_log_entries() -> int:
    """Count all valid audit entries in the full audit file."""
    total = 0
    skipped = 0

    try:
        with Path(AUDIT_LOG_PATH).open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                entry = _parse_audit_line(line)
                if entry is None:
                    skipped += 1
                    continue
                total += 1
    except FileNotFoundError:
        return 0
    except Exception as exc:
        logger.warning("Could not count audit log: %s", exc)
        return 0

    if skipped:
        logger.warning("Skipped %s malformed audit log line(s) while counting", skipped)

    return total
