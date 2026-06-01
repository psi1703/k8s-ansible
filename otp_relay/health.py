from fastapi import APIRouter, HTTPException

from otp_relay.config import REDIS_REQUIRED
from otp_relay.redis_state import _redis_status
from otp_relay.state import users

router = APIRouter()


@router.get("/healthz")
async def healthz():
    return {"status": "ok"}


@router.get("/livez")
async def livez():
    """Process liveness check.

    This endpoint intentionally does not depend on Redis. Redis availability is
    checked by /readyz so Kubernetes can remove the pod from service endpoints
    without killing and restarting the process during Redis/HAProxy failover.
    """
    return {"status": "ok"}


@router.get("/readyz")
async def readyz():
    redis_status = _redis_status()

    if REDIS_REQUIRED and redis_status != "ok":
        raise HTTPException(
            status_code=503,
            detail={
                "status": "not_ready",
                "users_loaded": len(users),
                "redis": redis_status,
                "redis_required": REDIS_REQUIRED,
            },
        )

    return {
        "status": "ok",
        "users_loaded": len(users),
        "redis": redis_status,
        "redis_required": REDIS_REQUIRED,
    }
