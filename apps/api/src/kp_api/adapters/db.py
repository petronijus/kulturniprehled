"""Async SQLAlchemy engine, session factory, and FastAPI dependency.

The engine is a process singleton constructed lazily from `Settings`. Tests
swap it out via `set_engine_override` so they can point at a Testcontainers
Postgres instance without monkey-patching.
"""

from collections.abc import AsyncIterator
from functools import lru_cache

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from kp_api.config import Settings, get_settings

_engine_override: AsyncEngine | None = None
_sessionmaker_override: async_sessionmaker[AsyncSession] | None = None


@lru_cache(maxsize=1)
def _default_engine() -> AsyncEngine:
    return _build_engine(get_settings())


def _build_engine(settings: Settings) -> AsyncEngine:
    return create_async_engine(
        settings.database_url,
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=5,
        future=True,
    )


def get_engine() -> AsyncEngine:
    return _engine_override or _default_engine()


@lru_cache(maxsize=1)
def _default_sessionmaker() -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(bind=_default_engine(), expire_on_commit=False)


def get_sessionmaker() -> async_sessionmaker[AsyncSession]:
    return _sessionmaker_override or _default_sessionmaker()


def set_engine_override(engine: AsyncEngine | None) -> None:
    """Replace the process-wide engine. Tests use this to point at a fixture DB."""

    global _engine_override, _sessionmaker_override
    _engine_override = engine
    _sessionmaker_override = (
        async_sessionmaker(bind=engine, expire_on_commit=False) if engine else None
    )


async def get_session() -> AsyncIterator[AsyncSession]:
    """FastAPI dependency yielding an `AsyncSession` and closing it after the request."""

    factory = get_sessionmaker()
    async with factory() as session:
        yield session
