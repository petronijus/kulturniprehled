"""Personal-access-token (PAT) flow used by the desktop Claude Code skill."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.auth import mint_pat, revoke_pat
from kp_api.config import Settings
from kp_api.domain.models import PersonalAccessToken, User
from tests.conftest import auth_header, login_as


@pytest.mark.asyncio
async def test_pat_authenticates_like_an_access_jwt(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    # Establish the user via Google login so we have a known User row.
    await login_as(client, "petr@example.com")
    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None
    pat = await mint_pat(db_session, user, name="skill", settings=settings)
    await db_session.commit()

    response = await client.get("/v1/events", headers=auth_header(pat))
    assert response.status_code == 200


@pytest.mark.asyncio
async def test_pat_updates_last_used_at(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    await login_as(client, "petr@example.com")
    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None
    pat = await mint_pat(db_session, user, name="skill", settings=settings)
    await db_session.commit()

    before = datetime.now(UTC)
    response = await client.get("/v1/events", headers=auth_header(pat))
    assert response.status_code == 200

    rows = (
        await db_session.scalars(
            select(PersonalAccessToken).where(PersonalAccessToken.user_id == user.id)
        )
    ).all()
    assert len(rows) == 1
    row = rows[0]
    assert row.last_used_at is not None
    assert row.last_used_at >= before


@pytest.mark.asyncio
async def test_revoked_pat_is_rejected(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    await login_as(client, "petr@example.com")
    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None
    pat = await mint_pat(db_session, user, name="skill", settings=settings)
    row = (
        await db_session.scalars(
            select(PersonalAccessToken).where(PersonalAccessToken.user_id == user.id)
        )
    ).one()
    await revoke_pat(db_session, row.jti)
    await db_session.commit()

    response = await client.get("/v1/events", headers=auth_header(pat))
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_unknown_pat_is_rejected(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    # Sign a PAT for a user, then drop the row so the jti is unknown.
    await login_as(client, "petr@example.com")
    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None
    pat = await mint_pat(db_session, user, name="skill", settings=settings)
    row = (
        await db_session.scalars(
            select(PersonalAccessToken).where(PersonalAccessToken.user_id == user.id)
        )
    ).one()
    await db_session.delete(row)
    await db_session.commit()

    response = await client.get("/v1/events", headers=auth_header(pat))
    assert response.status_code == 401
