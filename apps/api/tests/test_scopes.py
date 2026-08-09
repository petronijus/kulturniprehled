"""Scope-restricted PAT authorization.

A scoped token is default-denied: it reaches only endpoints declaring one of
its scopes, never the general surface. Unrestricted tokens (and interactive
access JWTs) keep working everywhere — backward compatibility for the desktop
skill token.
"""

from __future__ import annotations

from urllib.parse import urlsplit

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.auth import mint_pat
from kp_api.config import Settings
from kp_api.domain.models import User
from kp_api.domain.scopes import (
    SCOPE_DIGEST_READ,
    SCOPE_FEEDBACK_SIGN,
    SCOPE_SEASON_READ,
    SCOPE_SEASON_WRITE,
)
from tests.conftest import auth_header, login_as


async def _known_user(client: AsyncClient, db_session: AsyncSession) -> User:
    await login_as(client, "petr@example.com")
    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None
    return user


@pytest.mark.asyncio
async def test_scoped_pat_rejected_on_general_endpoint(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    user = await _known_user(client, db_session)
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_DIGEST_READ]
    )
    await db_session.commit()

    response = await client.get("/v1/events", headers=auth_header(pat))
    assert response.status_code == 403


@pytest.mark.asyncio
async def test_scoped_pat_allowed_on_its_scope(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    user = await _known_user(client, db_session)
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_DIGEST_READ]
    )
    await db_session.commit()

    response = await client.get("/v1/digest/context", headers=auth_header(pat))
    assert response.status_code == 200


@pytest.mark.asyncio
async def test_scoped_pat_rejected_without_required_scope(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    # A token scoped only to feedback-sign must not read the digest.
    user = await _known_user(client, db_session)
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_FEEDBACK_SIGN]
    )
    await db_session.commit()

    response = await client.get("/v1/digest/context", headers=auth_header(pat))
    assert response.status_code == 403


@pytest.mark.asyncio
async def test_unrestricted_pat_allowed_everywhere(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    user = await _known_user(client, db_session)
    pat = await mint_pat(db_session, user, name="desktop", settings=settings)  # no scopes
    await db_session.commit()

    assert (await client.get("/v1/events", headers=auth_header(pat))).status_code == 200
    assert (await client.get("/v1/digest/context", headers=auth_header(pat))).status_code == 200


@pytest.mark.asyncio
async def test_access_jwt_is_unrestricted_on_scoped_endpoint(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    response = await client.get("/v1/digest/context", headers=auth_header(pair["access_token"]))
    assert response.status_code == 200


@pytest.mark.asyncio
async def test_feedback_sign_scope_signs_links(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    user = await _known_user(client, db_session)
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_FEEDBACK_SIGN]
    )
    await db_session.commit()

    response = await client.post(
        "/v1/feedback/sign",
        headers=auth_header(pat),
        json={"week": "CW22", "items": [{"title": "Sukovo trio", "lane": "klasika"}]},
    )
    assert response.status_code == 200, response.text
    data = response.json()
    assert len(data) == 1
    assert "/v1/feedback/rate?t=" in data[0]["url_up"]
    assert "/v1/feedback/rate?t=" in data[0]["url_down"]
    assert data[0]["url_up"] != data[0]["url_down"]

    # The server-signed token must verify against the same secret on /rate.
    rate = urlsplit(data[0]["url_up"])
    confirm = await client.get(f"{rate.path}?{rate.query}")
    assert confirm.status_code == 200


_SEASON_PAYLOAD = {"label": "2026/27", "starts_on": "2025-09-01", "ends_on": "2026-06-30"}


@pytest.mark.asyncio
async def test_season_read_scope_reads_but_cannot_write(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    user = await _known_user(client, db_session)
    reader = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_SEASON_READ]
    )
    writer = await mint_pat(
        db_session, user, name="routine-w", settings=settings, scopes=[SCOPE_SEASON_WRITE]
    )
    await db_session.commit()

    denied_create = await client.post(
        "/v1/season/plans", json=_SEASON_PAYLOAD, headers=auth_header(reader)
    )
    assert denied_create.status_code == 403

    created = await client.post(
        "/v1/season/plans", json=_SEASON_PAYLOAD, headers=auth_header(writer)
    )
    assert created.status_code == 201, created.text
    season_id = created.json()["id"]

    assert (
        await client.get("/v1/season/plans/current", headers=auth_header(reader))
    ).status_code == 200
    assert (
        await client.get(f"/v1/season/plans/{season_id}/pool", headers=auth_header(reader))
    ).status_code == 200
    denied_put = await client.put(
        f"/v1/season/plans/{season_id}/pool", json={"items": []}, headers=auth_header(reader)
    )
    assert denied_put.status_code == 403


@pytest.mark.asyncio
async def test_digest_scope_cannot_reach_season(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    user = await _known_user(client, db_session)
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_DIGEST_READ]
    )
    await db_session.commit()

    assert (
        await client.get("/v1/season/plans/current", headers=auth_header(pat))
    ).status_code == 403


@pytest.mark.asyncio
async def test_unrestricted_credentials_pass_season_endpoints(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    user = await _known_user(client, db_session)
    pat = await mint_pat(db_session, user, name="desktop", settings=settings)  # no scopes
    await db_session.commit()

    created = await client.post("/v1/season/plans", json=_SEASON_PAYLOAD, headers=auth_header(pat))
    assert created.status_code == 201, created.text

    pair = await login_as(client, "petr@example.com")
    jwt_read = await client.get(
        "/v1/season/plans/current", headers=auth_header(pair["access_token"])
    )
    assert jwt_read.status_code == 200
