"""Trusted-LAN auth for the login-less planner.

A request with no Authorization header that did not come through the
Cloudflare Tunnel is treated as the workspace owner restricted to the
season scopes — and nothing else. Off by default (WEB_TRUSTED_LAN)."""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from unittest.mock import patch

import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from kp_api.config import Settings, get_settings
from kp_api.main import create_app
from tests.conftest import login_as
from tests.test_season import _season_payload

CF = {"CF-Connecting-IP": "203.0.113.7"}


@pytest_asyncio.fixture
async def lan_client(settings: Settings, engine: AsyncEngine) -> AsyncIterator[AsyncClient]:
    _ = settings, engine
    with patch.dict(os.environ, {"WEB_TRUSTED_LAN": "true"}, clear=False):
        get_settings.cache_clear()
        lan_app = create_app()
        # The stub verifier lives on the module-level app; bootstrap the
        # owner through a real login against this app instance instead.
        from kp_api.api.v1.auth import get_verifier
        from tests.conftest import StubVerifier

        lan_app.dependency_overrides[get_verifier] = lambda: StubVerifier({"petr@example.com"})
        transport = ASGITransport(app=lan_app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
    get_settings.cache_clear()


async def test_lan_request_reaches_season_surface(lan_client: AsyncClient) -> None:
    await login_as(lan_client, "petr@example.com")  # bootstraps the owner

    created = await lan_client.post("/v1/season/plans", json=_season_payload())
    assert created.status_code == 201, created.text

    current = await lan_client.get("/v1/season/plans/current")
    assert current.status_code == 200
    season_id = current.json()["id"]

    booked = await lan_client.get(f"/v1/season/plans/{season_id}/booked")
    assert booked.status_code == 200
    assert booked.json() == {"items": []}


async def test_lan_request_is_denied_on_general_surface(lan_client: AsyncClient) -> None:
    await login_as(lan_client, "petr@example.com")
    # Scoped principal → default-deny outside the season surface.
    assert (await lan_client.get("/v1/events")).status_code == 403
    assert (await lan_client.get("/v1/watchlist")).status_code == 403


async def test_cloudflare_path_gets_no_lan_trust(lan_client: AsyncClient) -> None:
    await login_as(lan_client, "petr@example.com")
    denied = await lan_client.get("/v1/season/plans/current", headers=CF)
    assert denied.status_code == 401


async def test_lan_trust_needs_bootstrapped_owner(lan_client: AsyncClient) -> None:
    # Fresh DB (no login happened in this test) → no owner to impersonate.
    response = await lan_client.get("/v1/season/plans/current")
    assert response.status_code == 401


async def test_trusted_lan_off_by_default(client: AsyncClient) -> None:
    # The default app (WEB_TRUSTED_LAN unset) refuses anonymous requests.
    await login_as(client, "petr@example.com")
    response = await client.get("/v1/season/plans/current")
    assert response.status_code == 401
