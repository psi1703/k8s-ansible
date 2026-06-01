import hashlib
import json
import os
import secrets
import time
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from typing import Any, Dict, List, Optional

import bcrypt
import openpyxl
from fastapi import APIRouter, File, Header, HTTPException, Request, UploadFile
from pydantic import BaseModel

from otp_relay.audit import audit, count_audit_log_entries, read_audit_log
import otp_relay.redis_state as redis_state
from otp_relay.config import (
    ADMIN_LOGIN_LOCKOUT_SECONDS,
    ADMIN_LOGIN_MAX_ATTEMPTS,
    ADMIN_LOGIN_WINDOW_SECONDS,
    ADMIN_TTL_SECONDS,
    CLAIM_EXPIRY_SEC,
    FROM_EMAIL,
    REDIS_REQUIRED,
    USERS_EXCEL_MAX_BYTES,
    USERS_EXCEL_PATH,
    WIZARD_CLIENT_SECRET_MIN_LENGTH,
    _now_iso,
    _utcnow_naive,
    logger,
)
from otp_relay.email_diag import send_email
from otp_relay.models import ConfigPayload, CredentialPayload, WizardRecord
from otp_relay.redis_state import (
    _redis_admin_login_attempt_key,
    _redis_admin_queue,
    _redis_admin_session_key,
    _redis_queue_lock,
    _use_redis_state,
)
from otp_relay.storage import _auth_db, _config_db, _save_auth_db, _save_config_db, _save_wizard_db, _wizard_db
from otp_relay.state import ADMIN_LOGIN_ATTEMPTS, ADMIN_SESSIONS, WIZARD_DB_LOCK, claim_queue, users
from otp_relay.users import load_users_from_excel

router = APIRouter()


def _purge_admin_sessions() -> None:
    """Expire stale in-memory admin sessions.

    Redis-backed admin sessions use native key TTLs, so there is nothing to
    purge here when Redis is active.
    """
    if _use_redis_state():
        return

    now_ts = datetime.now(timezone.utc).timestamp()
    stale = [session for session, ts in ADMIN_SESSIONS.items() if now_ts - ts > ADMIN_TTL_SECONDS]
    for session in stale:
        ADMIN_SESSIONS.pop(session, None)


def _create_admin_session() -> str:
    session = secrets.token_urlsafe(24)
    now_ts = datetime.now(timezone.utc).timestamp()

    # Keep the local copy as a fallback while REDIS_REQUIRED=0.
    ADMIN_SESSIONS[session] = now_ts

    if _use_redis_state():
        try:
            redis_state.redis_client.setex(_redis_admin_session_key(session), ADMIN_TTL_SECONDS, str(now_ts))
        except Exception as exc:
            if REDIS_REQUIRED:
                raise HTTPException(status_code=503, detail="Redis admin session store is unavailable") from exc
            logger.warning("Could not write admin session to Redis; using in-memory fallback: %s", exc)

    return session


def _delete_admin_session(session: str) -> None:
    ADMIN_SESSIONS.pop(session, None)

    if _use_redis_state():
        try:
            redis_state.redis_client.delete(_redis_admin_session_key(session))
        except Exception as exc:
            if REDIS_REQUIRED:
                raise HTTPException(status_code=503, detail="Redis admin session store is unavailable") from exc
            logger.warning("Could not delete admin session from Redis: %s", exc)


def _require_admin(session: Optional[str]) -> None:
    if not session:
        raise HTTPException(status_code=401, detail="Missing admin session")

    now_ts = datetime.now(timezone.utc).timestamp()

    if _use_redis_state():
        try:
            existing = redis_state.redis_client.get(_redis_admin_session_key(session))
            if not existing:
                raise HTTPException(status_code=401, detail="Invalid admin session")

            # Sliding expiration: every valid admin request refreshes the session TTL.
            redis_state.redis_client.setex(_redis_admin_session_key(session), ADMIN_TTL_SECONDS, str(now_ts))
            ADMIN_SESSIONS[session] = now_ts
            return
        except HTTPException:
            raise
        except Exception as exc:
            if REDIS_REQUIRED:
                raise HTTPException(status_code=503, detail="Redis admin session store is unavailable") from exc
            logger.warning("Could not validate admin session in Redis; using in-memory fallback: %s", exc)

    _purge_admin_sessions()
    ts = ADMIN_SESSIONS.get(session)
    if not ts:
        raise HTTPException(status_code=401, detail="Invalid admin session")
    ADMIN_SESSIONS[session] = now_ts


def _model_dump(model: BaseModel) -> Dict[str, Any]:
    """Support both Pydantic v1 and v2."""
    if hasattr(model, "model_dump"):
        return model.model_dump()
    return model.dict()


def _client_ip(request: Request) -> str:
    forwarded_for = request.headers.get("x-forwarded-for", "")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _default_login_attempt_row(now_ts: float) -> Dict[str, Any]:
    return {"count": 0, "window_start": now_ts, "locked_until": 0.0}


def _get_login_attempt_row(client_ip: str, now_ts: float) -> Dict[str, Any]:
    if _use_redis_state():
        try:
            row = redis_state.redis_client.hgetall(_redis_admin_login_attempt_key(client_ip))
            if row:
                return {
                    "count": int(row.get("count", 0) or 0),
                    "window_start": float(row.get("window_start", now_ts) or now_ts),
                    "locked_until": float(row.get("locked_until", 0.0) or 0.0),
                }
        except Exception as exc:
            if REDIS_REQUIRED:
                raise HTTPException(status_code=503, detail="Redis admin login-attempt store is unavailable") from exc
            logger.warning("Could not read admin login attempts from Redis; using in-memory fallback: %s", exc)

    return ADMIN_LOGIN_ATTEMPTS.get(client_ip, _default_login_attempt_row(now_ts))


def _save_login_attempt_row(client_ip: str, row: Dict[str, Any]) -> None:
    ADMIN_LOGIN_ATTEMPTS[client_ip] = row

    if _use_redis_state():
        try:
            redis_state.redis_client.hset(_redis_admin_login_attempt_key(client_ip), mapping={
                "count": int(row.get("count", 0)),
                "window_start": float(row.get("window_start", 0.0)),
                "locked_until": float(row.get("locked_until", 0.0)),
            })
            ttl = max(ADMIN_LOGIN_WINDOW_SECONDS, ADMIN_LOGIN_LOCKOUT_SECONDS)
            redis_state.redis_client.expire(_redis_admin_login_attempt_key(client_ip), ttl)
        except Exception as exc:
            if REDIS_REQUIRED:
                raise HTTPException(status_code=503, detail="Redis admin login-attempt store is unavailable") from exc
            logger.warning("Could not write admin login attempts to Redis; using in-memory fallback: %s", exc)


def _delete_login_attempt_row(client_ip: str) -> None:
    ADMIN_LOGIN_ATTEMPTS.pop(client_ip, None)

    if _use_redis_state():
        try:
            redis_state.redis_client.delete(_redis_admin_login_attempt_key(client_ip))
        except Exception as exc:
            if REDIS_REQUIRED:
                raise HTTPException(status_code=503, detail="Redis admin login-attempt store is unavailable") from exc
            logger.warning("Could not delete admin login attempts from Redis: %s", exc)


def _check_login_rate_limit(request: Request) -> None:
    key = _client_ip(request)
    now_ts = datetime.now(timezone.utc).timestamp()
    row = _get_login_attempt_row(key, now_ts)

    if float(row.get("locked_until", 0.0)) > now_ts:
        raise HTTPException(status_code=429, detail="Too many failed login attempts. Try again later.")

    if now_ts - float(row.get("window_start", now_ts)) > ADMIN_LOGIN_WINDOW_SECONDS:
        row = _default_login_attempt_row(now_ts)

    _save_login_attempt_row(key, row)


def _record_login_failure(request: Request) -> None:
    key = _client_ip(request)
    now_ts = datetime.now(timezone.utc).timestamp()
    row = _get_login_attempt_row(key, now_ts)

    if now_ts - float(row.get("window_start", now_ts)) > ADMIN_LOGIN_WINDOW_SECONDS:
        row = _default_login_attempt_row(now_ts)

    row["count"] = int(row.get("count", 0)) + 1
    if row["count"] >= ADMIN_LOGIN_MAX_ATTEMPTS:
        row["locked_until"] = now_ts + ADMIN_LOGIN_LOCKOUT_SECONDS
    _save_login_attempt_row(key, row)


def _record_login_success(request: Request) -> None:
    _delete_login_attempt_row(_client_ip(request))


def _hash_wizard_secret(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def _valid_wizard_owner(row: Dict[str, Any], client_secret: Optional[str]) -> bool:
    stored_hash = str(row.get("client_secret_hash") or "")
    if not stored_hash or not client_secret or len(client_secret) < WIZARD_CLIENT_SECRET_MIN_LENGTH:
        return False
    return secrets.compare_digest(stored_hash, _hash_wizard_secret(client_secret))


def _bind_wizard_client(row: Dict[str, Any], client_secret: Optional[str]) -> bool:
    """Silently bind or rebind a wizard record to the current browser client.

    The user token is the durable owner of wizard progress. The client secret is
    only a background edit marker, so stale PVC/browser state must not block a
    valid token from continuing its own wizard progress.
    """
    if not client_secret or len(client_secret) < WIZARD_CLIENT_SECRET_MIN_LENGTH:
        raise HTTPException(status_code=401, detail="Wizard client secret required")

    current_hash = _hash_wizard_secret(client_secret)
    if secrets.compare_digest(str(row.get("client_secret_hash") or ""), current_hash):
        return False

    row["client_secret_hash"] = current_hash
    row["client_bound_at"] = _now_iso()
    return True


def _public_wizard_record(row: Dict[str, Any]) -> Dict[str, Any]:
    public = dict(row)
    public.pop("client_secret_hash", None)
    return public


def _default_wizard_record(token: str) -> Dict[str, Any]:
    return {
        "token": token,
        "display_name": users[token]["name"],
        "iits_username": "",
        "adm_username": "",
        "completed": [],
        "adminCompleted": [],
        "iits_pw_date": None,
        "adm_pw_date": None,
        "vpn_date": None,
        "test_env": users[token].get("test_env", ""),
        "prod_env": users[token].get("prod_env", ""),
    }


@router.get("/admin/log")
async def get_log(limit: int = 200, x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)
    entries = read_audit_log(limit)
    total = count_audit_log_entries()
    return {"entries": entries, "total": total}


@router.get("/admin/queue")
async def get_queue(x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)

    if _use_redis_state():
        with _redis_queue_lock():
            return {"queue": _redis_admin_queue()}

    now = _utcnow_naive()
    return {
        "queue": [
            {
                "token": claim["token"],
                "name": claim["name"],
                "email": claim["email"],
                "claimed_at": claim["claimed_at"].strftime("%Y-%m-%dT%H:%M:%SZ"),
                "expires_in": max(0, int(CLAIM_EXPIRY_SEC - (now - claim["claimed_at"]).total_seconds())),
                "position": i + 1,
            }
            for i, claim in enumerate(claim_queue)
        ]
    }


@router.get("/admin/users")
async def list_users(x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)
    return {
        "count": len(users),
        "users": [
            {
                "token": user["token"],
                "name": user["name"],
                "email": user["email"],
                "test_env": user.get("test_env", ""),
                "prod_env": user.get("prod_env", ""),
            }
            for user in users.values()
        ],
    }


@router.get("/admin/users/status")
async def users_file_status(x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)
    path = Path(USERS_EXCEL_PATH)
    exists = path.exists()
    stat = path.stat() if exists else None
    return {
        "exists": exists,
        "path": str(path),
        "users_loaded": len(users),
        "size_bytes": stat.st_size if stat else 0,
        "updated_at": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat() if stat else None,
        "max_size_bytes": USERS_EXCEL_MAX_BYTES,
    }


@router.post("/admin/users/upload")
async def upload_users_excel(file: UploadFile = File(...), x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)

    filename = file.filename or "users.xlsx"
    if not filename.lower().endswith(".xlsx"):
        raise HTTPException(status_code=400, detail="Upload must be an .xlsx file")

    content = await file.read(USERS_EXCEL_MAX_BYTES + 1)
    if len(content) > USERS_EXCEL_MAX_BYTES:
        raise HTTPException(status_code=413, detail=f"users.xlsx is too large. Maximum size is {USERS_EXCEL_MAX_BYTES} bytes")

    target = Path(USERS_EXCEL_PATH)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = target.with_name(target.stem + ".upload.tmp.xlsx")

    try:
        # Fail fast if the file is not a valid workbook before touching the live users.xlsx.
        openpyxl.load_workbook(BytesIO(content), read_only=True).close()
        tmp_path.write_bytes(content)
        parsed_count = load_users_from_excel(str(tmp_path), replace_existing=False)
        if parsed_count <= 0:
            raise ValueError("users.xlsx did not contain any valid users")

        tmp_path.replace(target)
        count = load_users_from_excel(str(target), replace_existing=True)
        audit("users_excel_uploaded", detail=f"{filename} uploaded by admin; {count} users loaded")
        return {
            "status": "ok",
            "filename": filename,
            "users_loaded": count,
            "size_bytes": len(content),
            "path": str(target),
        }
    except HTTPException:
        raise
    except Exception as exc:
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass
        audit("users_excel_upload_failed", detail=str(exc), status="error")
        raise HTTPException(status_code=400, detail=f"Could not import users.xlsx: {exc}")


@router.post("/admin/reload-users")
async def reload_users(x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)
    if not os.path.exists(USERS_EXCEL_PATH):
        raise HTTPException(status_code=404, detail=f"Not found: {USERS_EXCEL_PATH}")
    count = load_users_from_excel(USERS_EXCEL_PATH, replace_existing=True)
    audit("users_reloaded", detail=f"{count} users loaded")
    return {"status": "ok", "users_loaded": count}


@router.get("/admin/smtp-test")
async def smtp_test(x_admin_session: Optional[str] = Header(default=None)):
    """Sends a test email to the relay account - use to verify Exchange connectivity."""
    _require_admin(x_admin_session)
    html = """<div style="font-family:Arial,sans-serif;padding:24px">
      <p>OTP Relay SMTP test - if you can read this, Exchange is working.</p>
    </div>"""
    try:
        send_email(FROM_EMAIL, "OTP Relay", "OTP Relay - SMTP connectivity test", html)
        return {"status": "ok", "sent_to": FROM_EMAIL}
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


@router.get("/admin/auth/status")
async def admin_auth_status():
    return {"configured": bool(_auth_db().get("password_hash"))}


@router.post("/admin/auth/setup")
async def admin_auth_setup(payload: CredentialPayload):
    cred = (payload.credential or "").strip()
    if len(cred) < 4:
        raise HTTPException(status_code=400, detail="Credential too short")
    db = _auth_db()
    if db.get("password_hash"):
        if not payload.current:
            raise HTTPException(status_code=400, detail="Current credential required")
        if not bcrypt.checkpw(payload.current.encode("utf-8"), db["password_hash"].encode("utf-8")):
            raise HTTPException(status_code=401, detail="Current credential incorrect")
    hashed = bcrypt.hashpw(cred.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
    _save_auth_db({"password_hash": hashed, "updated_at": _now_iso()})
    session = _create_admin_session()
    audit("admin_auth_setup", detail="Admin credential configured")
    return {"status": "ok", "session": session}


@router.post("/admin/auth/login")
async def admin_auth_login(payload: CredentialPayload, request: Request):
    _check_login_rate_limit(request)

    db = _auth_db()
    stored = db.get("password_hash")
    if not stored:
        raise HTTPException(status_code=400, detail="Admin credential not configured")
    if not bcrypt.checkpw((payload.credential or "").encode("utf-8"), stored.encode("utf-8")):
        _record_login_failure(request)
        audit("admin_auth_failed", detail="Incorrect admin credential", status="warn")
        raise HTTPException(status_code=401, detail="Incorrect credential")
    _record_login_success(request)
    session = _create_admin_session()
    audit("admin_auth_login", detail="Admin session opened")
    return {"status": "ok", "session": session}


@router.post("/admin/auth/logout")
async def admin_auth_logout(x_admin_session: Optional[str] = Header(default=None)):
    if x_admin_session:
        _delete_admin_session(x_admin_session)
    return {"status": "ok"}


@router.get("/admin/config")
async def admin_config(x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)
    return _config_db()


@router.post("/admin/config")
async def admin_config_save(payload: ConfigPayload, x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)
    tokens: List[str] = []
    for token in payload.admin_tokens:
        clean = str(token or "").strip().upper()
        if clean and clean not in tokens:
            tokens.append(clean)
    _save_config_db({"admin_tokens": tokens, "updated_at": _now_iso()})
    audit("admin_config_saved", detail=f"Configured admin tokens: {', '.join(tokens) or 'none'}")
    return {"status": "ok", "admin_tokens": tokens}


@router.post("/wizard/progress")
async def wizard_progress_save(
    payload: WizardRecord,
    x_wizard_client: Optional[str] = Header(default=None),
    x_admin_session: Optional[str] = Header(default=None),
):
    token = payload.token.strip().upper()
    if token not in users:
        raise HTTPException(status_code=404, detail="Unknown token")

    is_admin = False
    try:
        _require_admin(x_admin_session)
        is_admin = True
    except HTTPException:
        is_admin = False

    with WIZARD_DB_LOCK:
        db = _wizard_db()
        existing = db.get(token, {})

        if not is_admin:
            _bind_wizard_client(existing, x_wizard_client)

        row = _model_dump(payload)
        row["token"] = token
        row["updated_at"] = _now_iso()
        row["client_secret_hash"] = existing.get("client_secret_hash")
        if existing.get("client_bound_at"):
            row["client_bound_at"] = existing.get("client_bound_at")
        db[token] = row
        _save_wizard_db(db)

    audit("wizard_progress_saved", token=token, detail="Wizard profile/progress updated")
    return {"status": "ok", "record": _public_wizard_record(row)}


@router.get("/wizard/progress/{token}")
async def wizard_progress_get(
    token: str,
    x_wizard_client: Optional[str] = Header(default=None),
    x_admin_session: Optional[str] = Header(default=None),
):
    token = token.strip().upper()
    if token not in users:
        raise HTTPException(status_code=404, detail="Unknown token")

    is_admin = False
    try:
        _require_admin(x_admin_session)
        is_admin = True
    except HTTPException:
        is_admin = False

    with WIZARD_DB_LOCK:
        db = _wizard_db()
        row = db.get(token)

        if not row:
            row = _default_wizard_record(token)
            if not is_admin:
                _bind_wizard_client(row, x_wizard_client)
                row["updated_at"] = _now_iso()
                db[token] = row
                _save_wizard_db(db)
            return _public_wizard_record(row)

        if not is_admin:
            changed = _bind_wizard_client(row, x_wizard_client)
            if changed:
                row["updated_at"] = _now_iso()
                db[token] = row
                _save_wizard_db(db)

        return _public_wizard_record(row)


@router.get("/admin/wizard")
async def admin_wizard(x_admin_session: Optional[str] = Header(default=None)):
    _require_admin(x_admin_session)
    db = _wizard_db()
    merged = []
    for token, user in sorted(users.items()):
        rec = db.get(token, {})
        merged.append({
            "token": token,
            "display_name": rec.get("display_name") or user.get("name", ""),
            "email": user.get("email", ""),
            "iits_username": rec.get("iits_username", ""),
            "adm_username": rec.get("adm_username", ""),
            "completed": rec.get("completed", []),
            "adminCompleted": rec.get("adminCompleted", []),
            "iits_pw_date": rec.get("iits_pw_date"),
            "adm_pw_date": rec.get("adm_pw_date"),
            "vpn_date": rec.get("vpn_date"),
            "test_env": rec.get("test_env") or user.get("test_env", ""),
            "prod_env": rec.get("prod_env") or user.get("prod_env", ""),
            "updated_at": rec.get("updated_at"),
        })
    return {"users": merged}


@router.post("/api/onboard/notify")
async def onboard_notify(request: Request):
    payload = await request.json()
    token = str(payload.get("token", "") or "").strip().upper() or None
    detail = json.dumps(payload, sort_keys=True)[:500]
    audit("onboard_notify", token=token, detail=detail)
    return {"status": "ok", "received": payload, "ts": _now_iso()}
