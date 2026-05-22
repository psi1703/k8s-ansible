import asyncio

from fastapi import APIRouter, Request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from starlette.responses import Response

from otp_relay.config import logger
from otp_relay.state import claim_queue

router = APIRouter()

OTP_QUEUE_DEPTH = Gauge("otp_queue_depth", "Current OTP claim queue depth")
OTP_ACTIVE_USER = Gauge("otp_active_user", "Whether an OTP claimant is currently active at the front of the queue")
OTP_CLAIMS_TOTAL = Counter("otp_claims_total", "Total OTP claim requests accepted")
OTP_DELIVERED_TOTAL = Counter("otp_delivered_total", "Total OTPs delivered to users")
OTP_CLAIM_EXPIRED_TOTAL = Counter("otp_claim_expired_total", "Total OTP claims expired before delivery")
OTP_REQUEST_DURATION_SECONDS = Histogram(
    "otp_request_duration_seconds",
    "OTP Relay HTTP request duration in seconds",
    ["method", "path", "status"],
)


def _update_app_metrics() -> None:
    """Refresh live app gauges for Prometheus."""
    try:
        from otp_relay.redis_state import _redis_queue_tokens, _use_redis_state
        if _use_redis_state():
            depth = len(_redis_queue_tokens())
        else:
            depth = len(claim_queue)

        OTP_QUEUE_DEPTH.set(depth)
        OTP_ACTIVE_USER.set(1 if depth > 0 else 0)
    except Exception as exc:
        logger.warning("Could not update Prometheus app metrics: %s", exc)


async def metrics_middleware(request: Request, call_next):
    start = asyncio.get_running_loop().time()
    response = await call_next(request)
    elapsed = asyncio.get_running_loop().time() - start

    if request.url.path != "/metrics":
        route = request.scope.get("route")
        path = getattr(route, "path", request.url.path)
        OTP_REQUEST_DURATION_SECONDS.labels(
            method=request.method,
            path=path,
            status=str(response.status_code),
        ).observe(elapsed)

    return response


@router.get("/metrics", include_in_schema=False)
async def metrics():
    _update_app_metrics()
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
