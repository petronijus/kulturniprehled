"""FastAPI application entrypoint."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from kp_api import __version__
from kp_api.adapters.storage import minio as storage
from kp_api.api.v1 import (
    auth,
    costs,
    digest,
    events,
    feedback,
    healthz,
    stats,
    sync,
    tickets,
    watchlist,
)
from kp_api.config import get_settings
from kp_api.observability import (
    SecurityHeadersMiddleware,
    configure_limiter,
    configure_logging,
    limiter,
)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    # Idempotent bucket bootstrap so a fresh MinIO comes up ready to use.
    # We do not crash startup if MinIO is unreachable — the API still serves
    # /healthz and Postgres-only endpoints — but ticket / image endpoints
    # will 5xx until the bucket exists.
    try:
        storage.ensure_all_buckets()
    except Exception:  # noqa: S110 (bootstrap is best-effort; healthz still serves)
        pass
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    configure_logging(settings)
    app = FastAPI(
        title="Kulturní Přehled API",
        version=__version__,
        lifespan=lifespan,
    )
    # IP-based rate limiter — module-level singleton (see observability.py)
    # so route decorators in auth.py bind to it at import time. We just
    # toggle `enabled` here from runtime settings.
    configure_limiter(settings)
    app.state.limiter = limiter
    app.add_exception_handler(
        RateLimitExceeded,
        _rate_limit_exceeded_handler,  # type: ignore[arg-type]
    )
    app.add_middleware(SecurityHeadersMiddleware)
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
    app.include_router(feedback.router)
    app.include_router(digest.router)
    return app


app = create_app()
