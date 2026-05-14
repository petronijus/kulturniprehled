"""FastAPI application entrypoint."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from kp_api import __version__
from kp_api.adapters.storage import minio as storage
from kp_api.api.v1 import auth, costs, events, healthz, stats, sync, tickets, watchlist


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    # Idempotent bucket bootstrap so a fresh MinIO comes up ready to use.
    # We do not crash startup if MinIO is unreachable — the API still serves
    # /healthz and Postgres-only endpoints — but tickets endpoints will 5xx
    # until the bucket exists.
    try:
        storage.ensure_bucket()
    except Exception:  # noqa: BLE001 — bootstrap is best-effort
        pass
    yield


def create_app() -> FastAPI:
    app = FastAPI(
        title="Kulturní Přehled API",
        version=__version__,
        lifespan=lifespan,
    )
    app.include_router(healthz.router)
    app.include_router(auth.router)
    app.include_router(events.router)
    app.include_router(sync.router)
    app.include_router(tickets.router)
    app.include_router(tickets.events_router)
    app.include_router(costs.router)
    app.include_router(costs.events_router)
    app.include_router(stats.router)
    app.include_router(watchlist.router)
    return app


app = create_app()
