"""Shared pytest fixtures.

The whole test suite runs against a real Postgres instance booted by
Testcontainers — DB mocks are forbidden per project policy because the sync
layer (M2) relies on real `BIGSERIAL` ordering and Postgres JSONB semantics
that an in-memory fake will never match.

Per-test isolation is done with `TRUNCATE ... RESTART IDENTITY CASCADE` on
every table. That keeps fixtures simple and avoids the savepoint dance that
breaks once endpoints start doing their own commits.
"""

from __future__ import annotations

import os
import sys
from collections.abc import AsyncIterator, Iterator
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest
import pytest_asyncio
from alembic import command
from alembic.config import Config as AlembicConfig
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, create_async_engine
from testcontainers.postgres import PostgresContainer

from kp_api.adapters.db import set_engine_override
from kp_api.adapters.oauth import GoogleIdentity, IdTokenVerifier
from kp_api.api.v1.auth import get_verifier
from kp_api.config import Settings, get_settings
from kp_api.main import app

API_DIR = Path(__file__).resolve().parents[1]


class StubVerifier:
    """Fake `IdTokenVerifier` used by the auth tests.

    The `id_token` value passed by the test client is interpreted as the
    user's email so a single test can drive multiple identities without any
    network access."""

    def __init__(self, allowed: set[str]) -> None:
        self._allowed = allowed

    def verify(self, id_token: str) -> GoogleIdentity:
        email = id_token.lower().strip()
        if email not in self._allowed:
            from kp_api.adapters.oauth import OAuthError

            raise OAuthError("email not allowed")
        name = email.split("@", 1)[0].replace(".", " ").title()
        return GoogleIdentity(sub=f"google-{email}", email=email, name=name)


@pytest.fixture(scope="session")
def postgres() -> Iterator[PostgresContainer]:
    with PostgresContainer("postgres:16-alpine") as container:
        yield container


@pytest.fixture(scope="session")
def settings(postgres: PostgresContainer) -> Iterator[Settings]:
    env: dict[str, str] = {
        "POSTGRES_HOST": str(postgres.get_container_host_ip()),
        "POSTGRES_PORT": str(postgres.get_exposed_port(5432)),
        "POSTGRES_DB": str(postgres.dbname),
        "POSTGRES_USER": str(postgres.username),
        "POSTGRES_PASSWORD": str(postgres.password),
        "API_JWT_SECRET": "test-secret-test-secret-test-secret",
        "GOOGLE_OAUTH_CLIENT_ID": "test-client-id",
        "ALLOWED_EMAILS": "petr@example.com,bela@example.com",
    }
    with patch.dict(os.environ, env, clear=False):
        get_settings.cache_clear()
        yield get_settings()
    get_settings.cache_clear()


@pytest_asyncio.fixture(scope="session")
async def engine(settings: Settings) -> AsyncIterator[AsyncEngine]:
    engine = create_async_engine(settings.database_url, future=True)
    set_engine_override(engine)

    alembic_cfg = AlembicConfig(str(API_DIR / "alembic.ini"))
    alembic_cfg.set_main_option("script_location", str(API_DIR / "alembic"))
    alembic_cfg.set_main_option("prepend_sys_path", str(API_DIR / "src"))
    if str(API_DIR / "src") not in sys.path:
        sys.path.insert(0, str(API_DIR / "src"))
    command.upgrade(alembic_cfg, "head")

    try:
        yield engine
    finally:
        set_engine_override(None)
        await engine.dispose()


@pytest_asyncio.fixture(autouse=True)
async def _clean_db(engine: AsyncEngine) -> AsyncIterator[None]:
    async with engine.begin() as conn:
        await conn.execute(
            text(
                """
                TRUNCATE TABLE
                  applied_ops,
                  refresh_tokens,
                  change_log,
                  events,
                  workspace_members,
                  workspaces,
                  venues,
                  users
                RESTART IDENTITY CASCADE
                """
            )
        )
    yield


@pytest_asyncio.fixture
async def db_session(engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(bind=engine, expire_on_commit=False)
    async with factory() as session:
        yield session


@pytest_asyncio.fixture
async def client(settings: Settings, engine: AsyncEngine) -> AsyncIterator[AsyncClient]:
    _ = settings, engine  # ensures the DB is up before requests run
    app.dependency_overrides[get_verifier] = (
        lambda: StubVerifier({"petr@example.com", "bela@example.com"})
    )
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as async_client:
        yield async_client
    app.dependency_overrides.pop(get_verifier, None)


async def login_as(client: AsyncClient, email: str) -> dict[str, Any]:
    response = await client.post("/v1/auth/google", json={"id_token": email})
    assert response.status_code == 200, response.text
    return response.json()


def auth_header(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}
