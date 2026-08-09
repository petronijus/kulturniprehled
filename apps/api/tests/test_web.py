"""SPA static serving: mount conditionality, history-API fallback, and the
path-aware CSP split between the SPA document and the JSON surface."""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from pathlib import Path
from unittest.mock import patch

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from kp_api.config import get_settings
from kp_api.main import app as bare_app
from kp_api.main import create_app

_SPA_INDEX = "<!doctype html><title>KP Planner</title><div id=root></div>"
_SPA_ASSET = "console.log('kp');"


@pytest_asyncio.fixture
async def spa_client(tmp_path: Path) -> AsyncIterator[AsyncClient]:
    dist = tmp_path / "dist"
    (dist / "assets").mkdir(parents=True)
    (dist / "index.html").write_text(_SPA_INDEX)
    (dist / "assets" / "app.js").write_text(_SPA_ASSET)

    with patch.dict(os.environ, {"WEB_DIST_DIR": str(dist)}, clear=False):
        get_settings.cache_clear()
        spa_app = create_app()
        transport = ASGITransport(app=spa_app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
    get_settings.cache_clear()


async def test_spa_serves_index_and_assets(spa_client: AsyncClient) -> None:
    index = await spa_client.get("/app/")
    assert index.status_code == 200
    assert "KP Planner" in index.text

    asset = await spa_client.get("/app/assets/app.js")
    assert asset.status_code == 200
    assert asset.text == _SPA_ASSET


async def test_spa_deep_link_falls_back_to_index(spa_client: AsyncClient) -> None:
    deep = await spa_client.get("/app/scenare/2026-27")
    assert deep.status_code == 200
    assert "KP Planner" in deep.text


async def test_spa_gets_relaxed_csp_api_stays_locked(spa_client: AsyncClient) -> None:
    index = await spa_client.get("/app/")
    csp = index.headers["content-security-policy"]
    assert "default-src 'self'" in csp
    assert "script-src 'self' https://accounts.google.com" in csp
    assert "frame-src https://accounts.google.com" in csp
    assert "frame-ancestors 'none'" in csp

    api = await spa_client.get("/healthz")
    assert api.headers["content-security-policy"] == "default-src 'none'; frame-ancestors 'none'"


async def test_no_dist_dir_means_no_mount() -> None:
    # The module-level app was built without a web bundle on disk, so /app
    # must 404 with the strict API CSP.
    transport = ASGITransport(app=bare_app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/app/")
    assert response.status_code == 404
    assert (
        response.headers["content-security-policy"]
        == "default-src 'self'; img-src 'self' data:; style-src 'self'; "
        "script-src 'self' https://accounts.google.com; "
        "connect-src 'self' https://accounts.google.com; "
        "frame-src https://accounts.google.com; frame-ancestors 'none'; base-uri 'none'"
    )
