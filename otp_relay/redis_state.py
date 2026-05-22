import re
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

try:
    import redis
except ImportError:
    redis = None
from fastapi import HTTPException

from otp_relay.audit import audit
from otp_relay.config import CLAIM_EXPIRY_SEC, OTP_DISPLAY_SEC, REDIS_REQUIRED, REDIS_URL, _now_iso, _utcnow_naive, logger
from otp_relay.metrics import OTP_CLAIM_EXPIRED_TOTAL
from otp_relay.state import users

REDIS_QUEUE_KEY = "otp:queue"
REDIS_QUEUE_LOCK_KEY = "otp:lock:queue"
REDIS_CLAIM_PREFIX = "otp:claim:"
REDIS_PENDING_PREFIX = "otp:pending:"
REDIS_ADMIN_SESSION_PREFIX = "admin:session:"
REDIS_ADMIN_LOGIN_ATTEMPT_PREFIX = "admin:login_attempt:"

redis_client = None


def _redis_enabled() -> bool:
    return bool(REDIS_URL)


def _init_redis_client() -> None:
    global redis_client

    if not REDIS_URL:
        redis_client = None
        logger.info("Redis disabled; using in-memory runtime state")
        return

    if redis is None:
        redis_client = None
        message = "REDIS_URL is set but redis package is not installed"
        if REDIS_REQUIRED:
            raise RuntimeError(message)
        logger.warning(message)
        return

    redis_client = redis.Redis.from_url(
        REDIS_URL,
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
        health_check_interval=30,
    )

    try:
        redis_client.ping()
        logger.info("Redis connected: %s", REDIS_URL)
    except Exception as exc:
        redis_client = None
        if REDIS_REQUIRED:
            raise RuntimeError(f"Redis is required but not reachable: {exc}") from exc
        logger.warning("Redis not reachable; continuing with in-memory runtime state: %s", exc)


def _redis_status() -> str:
    if not REDIS_URL:
        return "disabled"

    if redis_client is None:
        return "unavailable"

    try:
        redis_client.ping()
        return "ok"
    except Exception:
        return "error"


def _use_redis_state() -> bool:
    return redis_client is not None


def _redis_claim_key(token: str) -> str:
    return f"{REDIS_CLAIM_PREFIX}{token}"


def _redis_pending_key(token: str) -> str:
    return f"{REDIS_PENDING_PREFIX}{token}"


def _redis_admin_session_key(session: str) -> str:
    return f"{REDIS_ADMIN_SESSION_PREFIX}{session}"


def _redis_admin_login_attempt_key(client_ip: str) -> str:
    safe_ip = re.sub(r"[^A-Za-z0-9_.:-]", "_", client_ip or "unknown")
    return f"{REDIS_ADMIN_LOGIN_ATTEMPT_PREFIX}{safe_ip}"


def _redis_queue_lock():
    if redis_client is None:
        raise HTTPException(status_code=503, detail="Redis queue is unavailable")

    lock = redis_client.lock(REDIS_QUEUE_LOCK_KEY, timeout=10, blocking_timeout=5)
    acquired = False
    try:
        acquired = lock.acquire(blocking=True)
        if not acquired:
            raise HTTPException(status_code=503, detail="OTP queue is busy. Try again.")
        yield
    finally:
        if acquired:
            try:
                lock.release()
            except Exception:
                pass


def _parse_redis_datetime(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value).astimezone(timezone.utc).replace(tzinfo=None)
    except Exception:
        return _utcnow_naive()


def _redis_queue_tokens() -> List[str]:
    if redis_client is None:
        return []
    return [str(token).upper() for token in redis_client.lrange(REDIS_QUEUE_KEY, 0, -1)]


def _redis_get_claim(token: str) -> Optional[Dict[str, Any]]:
    if redis_client is None:
        return None
    row = redis_client.hgetall(_redis_claim_key(token))
    if not row:
        return None
    return {
        "token": str(row.get("token") or token).upper(),
        "name": str(row.get("name") or users.get(token, {}).get("name", "")),
        "email": str(row.get("email") or users.get(token, {}).get("email", "")),
        "claimed_at": _parse_redis_datetime(str(row.get("claimed_at") or "")),
    }


def _redis_remove_claim(token: str) -> None:
    if redis_client is None:
        return
    token = token.upper()
    redis_client.lrem(REDIS_QUEUE_KEY, 0, token)
    redis_client.delete(_redis_claim_key(token))


def _redis_purge_expired_claims() -> None:
    if redis_client is None:
        return

    now = _utcnow_naive()
    while True:
        token = redis_client.lindex(REDIS_QUEUE_KEY, 0)
        if not token:
            return
        token = str(token).upper()
        claim = _redis_get_claim(token)
        if not claim:
            redis_client.lpop(REDIS_QUEUE_KEY)
            redis_client.delete(_redis_claim_key(token))
            continue

        age = (now - claim["claimed_at"]).total_seconds()
        if age <= CLAIM_EXPIRY_SEC:
            return

        redis_client.lpop(REDIS_QUEUE_KEY)
        redis_client.delete(_redis_claim_key(token))
        audit("claim_expired", token, f"No OTP arrived within {CLAIM_EXPIRY_SEC}s - evicted from slot 1", "warn")
        OTP_CLAIM_EXPIRED_TOTAL.inc()


def _redis_get_pending_otp(token: str) -> Optional[Dict[str, Any]]:
    if redis_client is None:
        return None

    token = token.upper()
    key = _redis_pending_key(token)
    row = redis_client.hgetall(key)
    if not row:
        return None

    ttl = redis_client.ttl(key)
    if ttl == -2:
        return None
    if ttl == -1:
        arrived_at = _parse_redis_datetime(str(row.get("arrived_at") or ""))
        age = (_utcnow_naive() - arrived_at).total_seconds()
        ttl = max(0, int(OTP_DISPLAY_SEC - age))
        redis_client.expire(key, ttl)

    return {
        "otp": str(row.get("otp") or "-"),
        "arrived_at": _parse_redis_datetime(str(row.get("arrived_at") or "")),
        "expires_in": max(0, int(ttl)),
    }


def _redis_set_pending_otp(token: str, otp: str) -> None:
    if redis_client is None:
        return

    key = _redis_pending_key(token.upper())
    redis_client.hset(key, mapping={"otp": otp, "arrived_at": _now_iso()})
    redis_client.expire(key, OTP_DISPLAY_SEC)


def _redis_delete_pending_otp(token: str) -> bool:
    if redis_client is None:
        return False
    return bool(redis_client.delete(_redis_pending_key(token.upper())))


def _redis_add_claim(token: str) -> Dict[str, Any]:
    if redis_client is None:
        raise HTTPException(status_code=503, detail="Redis queue is unavailable")

    token = token.upper()
    now = _utcnow_naive()
    claim = {
        "token": token,
        "name": users[token]["name"],
        "email": users[token]["email"],
        "claimed_at": now,
    }
    redis_client.hset(_redis_claim_key(token), mapping={
        "token": token,
        "name": claim["name"],
        "email": claim["email"],
        "claimed_at": now.replace(tzinfo=timezone.utc).isoformat(),
    })
    redis_client.rpush(REDIS_QUEUE_KEY, token)
    return claim


def _redis_queue_position(token: str) -> int:
    token = token.upper()
    for index, queued_token in enumerate(_redis_queue_tokens(), start=1):
        if queued_token == token:
            return index
    return 0


def _redis_pop_next_claim() -> Optional[Dict[str, Any]]:
    if redis_client is None:
        return None

    _redis_purge_expired_claims()
    while True:
        token = redis_client.lpop(REDIS_QUEUE_KEY)
        if not token:
            return None
        token = str(token).upper()
        claim = _redis_get_claim(token)
        redis_client.delete(_redis_claim_key(token))
        if claim:
            return claim


def _redis_admin_queue() -> List[Dict[str, Any]]:
    if redis_client is None:
        return []

    _redis_purge_expired_claims()
    now = _utcnow_naive()
    rows: List[Dict[str, Any]] = []
    for index, token in enumerate(_redis_queue_tokens(), start=1):
        claim = _redis_get_claim(token)
        if not claim:
            continue
        rows.append({
            "token": claim["token"],
            "name": claim["name"],
            "email": claim["email"],
            "claimed_at": claim["claimed_at"].strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expires_in": max(0, int(CLAIM_EXPIRY_SEC - (now - claim["claimed_at"]).total_seconds())),
            "position": index,
        })
    return rows
