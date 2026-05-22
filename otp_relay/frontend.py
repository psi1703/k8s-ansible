from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from otp_relay.config import FRONTEND_DIR

router = APIRouter()


@router.get("/guide.html", include_in_schema=False)
def serve_guide_html():
    guide_path = FRONTEND_DIR / "guide.html"
    if not guide_path.exists():
        raise HTTPException(status_code=404, detail="guide.html not deployed")
    return FileResponse(guide_path)


def mount_frontend(app) -> None:
    app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
