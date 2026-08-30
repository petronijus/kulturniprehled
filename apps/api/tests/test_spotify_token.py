"""The planner's Spotify token: home-only, cached, degrading gracefully.

`AsyncClient.post` is patched wholesale (the adapter builds its own client),
so every test authenticates first — otherwise the stub would answer the test
client's own login request too.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from unittest.mock import patch

import httpx
import pytest
from httpx import ASGITransport, AsyncClient

from kp_api.adapters import spotify
from kp_api.config import get_settings
from tests.conftest import auth_header, login_as

CREDS = {
    "SPOTIFY_CLIENT_ID": "client",
    "SPOTIFY_CLIENT_SECRET": "secret",
    "SPOTIFY_REFRESH_TOKEN": "refresh",
}


@pytest.fixture(autouse=True)
def _clear_cache() -> None:
    spotify.reset_cache()


@pytest.fixture
async def spotify_client(settings: object, engine: object) -> AsyncIterator[AsyncClient]:
    """An app configured with (stub) Spotify credentials."""

    _ = settings, engine
    with patch.dict(os.environ, CREDS, clear=False):
        get_settings.cache_clear()
        from kp_api.api.v1.auth import get_verifier
        from kp_api.main import create_app
        from tests.conftest import StubVerifier

        app = create_app()
        app.dependency_overrides[get_verifier] = lambda: StubVerifier({"petr@example.com"})
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
    get_settings.cache_clear()


async def _auth(client: AsyncClient) -> dict[str, str]:
    pair = await login_as(client, "petr@example.com")
    return auth_header(pair["access_token"])


async def test_token_is_minted_and_then_served_from_cache(
    spotify_client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = {"n": 0}

    async def fake_post(self: httpx.AsyncClient, url: str, **kwargs: object) -> httpx.Response:
        calls["n"] += 1
        return httpx.Response(200, json={"access_token": "tok-123", "expires_in": 3600})

    headers = await _auth(spotify_client)
    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    first = await spotify_client.get("/v1/season/spotify-token", headers=headers)
    second = await spotify_client.get("/v1/season/spotify-token", headers=headers)

    assert first.status_code == 200, first.text
    assert first.json()["access_token"] == "tok-123"
    assert second.json()["access_token"] == "tok-123"
    # One refresh serves both reads — the SDK asks on every player init.
    assert calls["n"] == 1


async def test_cloudflare_path_never_gets_a_token(
    spotify_client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Season reads are public with a scoped PAT; Spotify access is not."""

    async def fake_post(self: httpx.AsyncClient, url: str, **kwargs: object) -> httpx.Response:
        return httpx.Response(200, json={"access_token": "tok-123", "expires_in": 3600})

    headers = await _auth(spotify_client)
    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    response = await spotify_client.get(
        "/v1/season/spotify-token",
        headers={**headers, "CF-Connecting-IP": "203.0.113.9"},
    )

    assert response.status_code == 404


async def test_unconfigured_spotify_degrades_to_503(client: AsyncClient) -> None:
    """The default test settings carry no Spotify credentials."""

    pair = await login_as(client, "petr@example.com")
    response = await client.get(
        "/v1/season/spotify-token", headers=auth_header(pair["access_token"])
    )

    assert response.status_code == 503


async def test_a_rejected_refresh_token_is_not_fatal(
    spotify_client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_post(self: httpx.AsyncClient, url: str, **kwargs: object) -> httpx.Response:
        return httpx.Response(400, json={"error": "invalid_grant"})

    headers = await _auth(spotify_client)
    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    response = await spotify_client.get("/v1/season/spotify-token", headers=headers)

    assert response.status_code == 503
    # The client id must never travel back to the caller.
    assert "client" not in response.text
