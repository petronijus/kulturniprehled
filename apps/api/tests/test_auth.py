"""Auth flow tests: Google ID-token login, refresh rotation, reuse detection."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


@pytest.mark.asyncio
async def test_login_with_allowed_email_returns_token_pair(client: AsyncClient) -> None:
    body = await login_as(client, "petr@example.com")
    assert body["token_type"] == "Bearer"
    assert body["access_token"]
    assert body["refresh_token"]
    assert body["access_expires_at"]
    assert body["refresh_expires_at"]


@pytest.mark.asyncio
async def test_login_with_unknown_email_is_rejected(client: AsyncClient) -> None:
    response = await client.post("/v1/auth/google", json={"id_token": "stranger@example.com"})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_refresh_rotates_and_old_refresh_is_burnt(client: AsyncClient) -> None:
    first = await login_as(client, "petr@example.com")
    refreshed = await client.post(
        "/v1/auth/refresh", json={"refresh_token": first["refresh_token"]}
    )
    assert refreshed.status_code == 200
    new_pair = refreshed.json()
    assert new_pair["refresh_token"] != first["refresh_token"]

    # Reusing the original refresh must fail AND burn the whole family.
    reuse = await client.post("/v1/auth/refresh", json={"refresh_token": first["refresh_token"]})
    assert reuse.status_code == 401

    # After reuse detection the second (legitimate) refresh is revoked too.
    after_reuse = await client.post(
        "/v1/auth/refresh", json={"refresh_token": new_pair["refresh_token"]}
    )
    assert after_reuse.status_code == 401


@pytest.mark.asyncio
async def test_logout_revokes_family(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    response = await client.post("/v1/auth/logout", json={"refresh_token": pair["refresh_token"]})
    assert response.status_code == 204
    after = await client.post("/v1/auth/refresh", json={"refresh_token": pair["refresh_token"]})
    assert after.status_code == 401


@pytest.mark.asyncio
async def test_protected_endpoint_requires_bearer(client: AsyncClient) -> None:
    response = await client.get("/v1/events")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_protected_endpoint_accepts_valid_bearer(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    response = await client.get("/v1/events", headers=auth_header(pair["access_token"]))
    assert response.status_code == 200


@pytest.mark.asyncio
async def test_protected_endpoint_rejects_tampered_bearer(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    tampered = pair["access_token"] + "x"
    response = await client.get("/v1/events", headers=auth_header(tampered))
    assert response.status_code == 401
