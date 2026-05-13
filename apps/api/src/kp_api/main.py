"""FastAPI application entrypoint."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from kp_api import __version__
from kp_api.api.v1 import auth, events, healthz


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
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
    return app


app = create_app()
