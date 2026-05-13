"""FastAPI application entrypoint."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from kp_api import __version__
from kp_api.api.v1 import healthz


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
    return app


app = create_app()
