import asyncio
import re
from typing import Optional

from fastapi import APIRouter, HTTPException, Request

from otp_relay.audit import audit, read_audit_log
from otp_relay.config import CLAIM_EXPIRY_SEC, CONCURRENT_RISK_SEC, OTP_DISPLAY_SEC, SMS_SECRET_TOKEN, _utcnow_naive
from otp_relay.metrics import OTP_CLAIM_EXPIRED_TOTAL, OTP_CLAIMS_TOTAL, OTP_DELIVERED_TOTAL
from otp_relay.models import UserLoginPayload
from otp_relay.redis_state import (
    _redis_add_claim,
    _redis_delete_pending_otp,
    _redis_get_claim,
    _redis_get_pending_otp,
    _redis_pop_next_claim,
    _redis_purge_expired_claims,
    _redis_queue_lock,
    _redis_queue_position,
    _redis_queue_tokens,
    _redis_remove_claim,
    _redis_set_pending_otp,
    _use_redis_state,
)
from otp_relay.state import claim_queue, pending_otps, users

router = APIRouter()


def purge_expired() -> None:
    """Evict the front-of-queue claim if it has exceeded CLAIM_EXPIRY_SEC."""
    if _use_redis_state():
        with _redis_queue_lock():
            _redis_purge_expired_claims()
        return

    now = _utcnow_naive()
    while claim_queue:
        age = (now - claim_queue[0]["claimed_at"]).total_seconds()
        if age > CLAIM_EXPIRY_SEC:
            expired = claim_queue.popleft()
            audit("claim_expired", expired["token"], f"No OTP arrived within {CLAIM_EXPIRY_SEC}s - evicted from slot 1", "warn")
            OTP_CLAIM_EXPIRED_TOTAL.inc()
        else:
            break


def purge_stale_otps() -> None:
    """Remove delivered OTPs that have exceeded OTP_DISPLAY_SEC."""
    if _use_redis_state():
        # Redis expires pending OTPs with key TTL. No disk/log copy is kept.
        return

    now = _utcnow_naive()
    stale = [
        token for token, value in pending_otps.items()
        if (now - value["arrived_at"]).total_seconds() > OTP_DISPLAY_SEC
    ]
    for token in stale:
        del pending_otps[token]
        audit("otp_display_expired", token, f"OTP display window closed after {OTP_DISPLAY_SEC}s")


def extract_otp(text: str) -> str:
    match = re.search(r"\b\d{4,8}\b", text)
    return match.group() if match else "-"


async def background_purge() -> None:
    """Runs every 15 seconds to expire stale queue entries and OTP display windows."""
    while True:
        await asyncio.sleep(15)
        purge_expired()
        purge_stale_otps()


@router.post("/user/login")
async def user_login(payload: UserLoginPayload):
    """Validate one user token without exposing the full admin-only user directory."""
    token = str(payload.token or "").strip().upper()
    if token not in users:
        audit("user_login_failed", token=token, detail="Unknown token", status="warn")
        raise HTTPException(status_code=404, detail="Token not recognised. Check with IT.")

    user = users[token]
    audit("user_login", token=token, detail="User token validated")
    return {
        "token": user["token"],
        "name": user["name"],
        "email": user["email"],
        "test_env": user.get("test_env", ""),
        "prod_env": user.get("prod_env", ""),
    }


@router.post("/claim-otp")
async def claim_otp(request: Request):
    data = await request.json()
    token = str(data.get("token", "")).strip().upper()

    if token not in users:
        audit("claim_rejected", token, "Unknown token", "error")
        raise HTTPException(status_code=404, detail="Token not recognised. Check with your IT department.")

    if _use_redis_state():
        with _redis_queue_lock():
            _redis_purge_expired_claims()

            pending = _redis_get_pending_otp(token)
            if pending:
                return {"status": "otp_ready", "expires_in": pending["expires_in"]}

            position = _redis_queue_position(token)
            if position:
                claim = _redis_get_claim(token)
                remaining = CLAIM_EXPIRY_SEC
                if claim:
                    age = (_utcnow_naive() - claim["claimed_at"]).total_seconds()
                    remaining = max(0, int(CLAIM_EXPIRY_SEC - age))
                audit("claim_duplicate", token, f"Already at position {position}", "warn")
                return {
                    "status": "already_queued",
                    "position": position,
                    "expires_in": remaining,
                    "queue_depth": len(_redis_queue_tokens()),
                }

            tokens = _redis_queue_tokens()
            if tokens:
                front_claim = _redis_get_claim(tokens[0])
                if front_claim:
                    front_age = (_utcnow_naive() - front_claim["claimed_at"]).total_seconds()
                    if front_age < CONCURRENT_RISK_SEC:
                        audit(
                            "concurrent_risk",
                            token,
                            f"New claim while {front_claim['token']} has been active for only {int(front_age)}s",
                            "warn",
                        )

            _redis_add_claim(token)
            OTP_CLAIMS_TOTAL.inc()
            position = _redis_queue_position(token)
            queue_depth = len(_redis_queue_tokens())
            wait_estimate = max(0, (position - 1) * CLAIM_EXPIRY_SEC)

            audit("claim_queued", token, f"Queue position {position} of {queue_depth}")
            return {
                "status": "queued",
                "position": position,
                "name": users[token]["name"],
                "expires_in": CLAIM_EXPIRY_SEC,
                "queue_depth": queue_depth,
                "wait_estimate": wait_estimate,
            }

    purge_expired()
    purge_stale_otps()

    for i, claim in enumerate(claim_queue):
        if claim["token"] == token:
            age = (_utcnow_naive() - claim["claimed_at"]).total_seconds()
            remaining = max(0, int(CLAIM_EXPIRY_SEC - age))
            audit("claim_duplicate", token, f"Already at position {i + 1}", "warn")
            return {
                "status": "already_queued",
                "position": i + 1,
                "expires_in": remaining,
                "queue_depth": len(claim_queue),
            }

    if token in pending_otps:
        age = (_utcnow_naive() - pending_otps[token]["arrived_at"]).total_seconds()
        remaining = max(0, int(OTP_DISPLAY_SEC - age))
        return {"status": "otp_ready", "expires_in": remaining}

    now = _utcnow_naive()

    if claim_queue:
        front_age = (now - claim_queue[0]["claimed_at"]).total_seconds()
        if front_age < CONCURRENT_RISK_SEC:
            audit(
                "concurrent_risk",
                token,
                f"New claim while {claim_queue[0]['token']} has been active for only {int(front_age)}s",
                "warn",
            )

    claim_queue.append({
        "token": token,
        "name": users[token]["name"],
        "email": users[token]["email"],
        "claimed_at": now,
    })
    OTP_CLAIMS_TOTAL.inc()

    position = len(claim_queue)
    queue_depth = len(claim_queue)
    wait_estimate = max(0, (position - 1) * CLAIM_EXPIRY_SEC)

    audit("claim_queued", token, f"Queue position {position} of {queue_depth}")
    return {
        "status": "queued",
        "position": position,
        "name": users[token]["name"],
        "expires_in": CLAIM_EXPIRY_SEC,
        "queue_depth": queue_depth,
        "wait_estimate": wait_estimate,
    }


@router.get("/claim-status/{token}")
async def claim_status(token: str):
    token = token.upper()

    if _use_redis_state():
        with _redis_queue_lock():
            _redis_purge_expired_claims()

            pending = _redis_get_pending_otp(token)
            if pending:
                return {"status": "delivered", "otp": pending["otp"], "expires_in": pending["expires_in"]}

            position = _redis_queue_position(token)
            if position:
                claim = _redis_get_claim(token)
                if claim:
                    age = (_utcnow_naive() - claim["claimed_at"]).total_seconds()
                    remaining = max(0, int(CLAIM_EXPIRY_SEC - age))
                    wait_estimate = max(0, (position - 1) * CLAIM_EXPIRY_SEC)
                    return {
                        "status": "waiting",
                        "position": position,
                        "expires_in": remaining,
                        "queue_depth": len(_redis_queue_tokens()),
                        "wait_estimate": wait_estimate,
                    }

        for entry in read_audit_log(500):
            if entry.get("token") == token:
                if entry["event"] in ("otp_delivered", "otp_display_expired"):
                    return {"status": "done"}
                if entry["event"] == "claim_expired":
                    return {"status": "idle_expired"}
                break

        return {"status": "unknown"}

    purge_expired()
    purge_stale_otps()

    if token in pending_otps:
        age = (_utcnow_naive() - pending_otps[token]["arrived_at"]).total_seconds()
        remaining = max(0, int(OTP_DISPLAY_SEC - age))
        return {"status": "delivered", "otp": pending_otps[token]["otp"], "expires_in": remaining}

    for i, claim in enumerate(claim_queue):
        if claim["token"] == token:
            age = (_utcnow_naive() - claim["claimed_at"]).total_seconds()
            remaining = max(0, int(CLAIM_EXPIRY_SEC - age))
            wait_estimate = max(0, i * CLAIM_EXPIRY_SEC)
            return {
                "status": "waiting",
                "position": i + 1,
                "expires_in": remaining,
                "queue_depth": len(claim_queue),
                "wait_estimate": wait_estimate,
            }

    for entry in read_audit_log(500):
        if entry.get("token") == token:
            if entry["event"] in ("otp_delivered", "otp_display_expired"):
                return {"status": "done"}
            if entry["event"] == "claim_expired":
                return {"status": "idle_expired"}
            break

    return {"status": "unknown"}


@router.delete("/claim-otp/{token}")
async def cancel_claim(token: str):
    """Discard a delivered OTP and remove/requeue claim state for retry flows."""
    token = token.upper()

    if _use_redis_state():
        with _redis_queue_lock():
            if _redis_delete_pending_otp(token):
                audit("otp_discarded", token, "User requested retry - OTP discarded from Redis")

            position = _redis_queue_position(token)
            _redis_remove_claim(token)
            if position:
                audit("claim_cancelled", token, "Removed from queue by user")

        return {"status": "ok"}

    if token in pending_otps:
        del pending_otps[token]
        audit("otp_discarded", token, "User requested retry - OTP discarded from memory")

    before = len(claim_queue)
    kept_claims = [claim for claim in claim_queue if claim["token"] != token]
    claim_queue.clear()
    claim_queue.extend(kept_claims)
    if len(claim_queue) < before:
        audit("claim_cancelled", token, "Removed from queue by user")

    return {"status": "ok"}


@router.post("/sms-received")
async def sms_received(request: Request):
    if request.headers.get("X-Secret-Token", "") != SMS_SECRET_TOKEN:
        audit("sms_rejected", detail="Wrong secret token", status="error")
        raise HTTPException(status_code=401)

    data = await request.json()
    sms_body = str(data.get("body", "")).strip()
    audit("sms_received", detail=f"SMS arrived ({len(sms_body)} chars)")

    if _use_redis_state():
        with _redis_queue_lock():
            recipient = _redis_pop_next_claim()

        if not recipient:
            await asyncio.sleep(4)
            with _redis_queue_lock():
                recipient = _redis_pop_next_claim()

        if not recipient:
            audit("sms_unmatched", detail="No claimant in queue - SMS discarded", status="warn")
            return {"status": "no_claimant"}

        otp = extract_otp(sms_body)
        _redis_set_pending_otp(recipient["token"], otp)

        audit("otp_delivered", recipient["token"], "OTP ready for display - queue unblocked")
        OTP_DELIVERED_TOTAL.inc()
        return {"status": "delivered", "recipient": recipient["name"]}

    purge_expired()
    purge_stale_otps()

    if not claim_queue:
        await asyncio.sleep(4)
        purge_expired()
        if not claim_queue:
            audit("sms_unmatched", detail="No claimant in queue - SMS discarded", status="warn")
            return {"status": "no_claimant"}

    recipient = claim_queue.popleft()
    otp = extract_otp(sms_body)

    pending_otps[recipient["token"]] = {"otp": otp, "arrived_at": _utcnow_naive()}

    audit("otp_delivered", recipient["token"], "OTP ready for display - queue unblocked")
    OTP_DELIVERED_TOTAL.inc()
    return {"status": "delivered", "recipient": recipient["name"]}
