# OTP Relay FastAPI application assembly.
# Business logic lives in focused modules under otp_relay/.

import asyncio
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from otp_relay.admin import router as admin_router
from otp_relay.audit import audit
from otp_relay.config import USERS_EXCEL_PATH, logger
from otp_relay.frontend import mount_frontend, router as frontend_router
from otp_relay.health import router as health_router
from otp_relay.metrics import metrics_middleware, router as metrics_router
from otp_relay.otp_flow import background_purge, router as otp_router
from otp_relay.redis_state import _init_redis_client
from otp_relay.storage import _ensure_data_dir
from otp_relay.users import load_users_from_excel

app = FastAPI(title="OTP Relay")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # safe for current LAN-only deployment
    allow_methods=["*"],
    allow_headers=["*"],
)

app.middleware("http")(metrics_middleware)
app.include_router(metrics_router)
app.include_router(health_router)
app.include_router(otp_router)
app.include_router(admin_router)
app.include_router(frontend_router)


@app.on_event("startup")
async def startup() -> None:
    _ensure_data_dir()
    _init_redis_client()
    if os.path.exists(USERS_EXCEL_PATH):
        count = load_users_from_excel(USERS_EXCEL_PATH)
        audit("server_start", detail=f"{count} users loaded")
    else:
        logger.warning("users.xlsx not found at %s", USERS_EXCEL_PATH)
        audit("server_start", detail="No users.xlsx - POST /admin/reload-users after adding it", status="warn")
    asyncio.create_task(background_purge())


# Static frontend must be mounted last.
mount_frontend(app)
