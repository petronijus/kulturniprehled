"""Liveness probe endpoint."""

from fastapi import APIRouter

from kp_api import __version__

router = APIRouter(tags=["meta"])


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok", "version": __version__}
