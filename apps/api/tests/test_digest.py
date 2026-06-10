"""Weekly-digest context endpoint — balance signal, booked list, feedback."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.auth import mint_pat
from kp_api.adapters.discogs import DiscogsRelease, DiscogsTaste
from kp_api.api.v1.digest import provide_discogs_taste
from kp_api.config import Settings
from kp_api.domain.enums import FeedbackRating
from kp_api.domain.ids import uuid7
from kp_api.domain.models import RecommendationFeedback, User
from kp_api.domain.scopes import SCOPE_DIGEST_READ
from kp_api.main import app
from tests.conftest import auth_header, login_as


def _payload(category: str, days: int, title: str) -> dict[str, object]:
    when = datetime.now(UTC) + timedelta(days=days)
    return {
        "title": title,
        "category": category,
        "starts_at": when.isoformat().replace("+00:00", "Z"),
    }


@pytest.mark.asyncio
async def test_digest_context_balance_and_booked(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    pair = await login_as(client, "petr@example.com")
    access = auth_header(pair["access_token"])

    # A concert 10 days ago (drives days-since) and one booked 14 days out.
    await client.post("/v1/events", json=_payload("concert", -10, "Past Concert"), headers=access)
    await client.post("/v1/events", json=_payload("concert", 14, "Future Concert"), headers=access)

    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_DIGEST_READ]
    )
    await db_session.commit()

    response = await client.get("/v1/digest/context", headers=auth_header(pat))
    assert response.status_code == 200, response.text
    body = response.json()

    assert body["balance"]["days_since"]["concert"] == 10
    # Never been to theatre/cinema in-window → sentinel 999.
    assert body["balance"]["days_since"]["theatre"] == 999
    # 10 days since a concert → damped below 1.0; theatre untouched → boosted.
    assert body["balance"]["multiplier"]["klasika"] < 1.0
    assert body["balance"]["multiplier"]["divadlo"] > 1.0
    # elektronika shares the concert lane with klasika.
    assert body["balance"]["multiplier"]["elektronika"] == body["balance"]["multiplier"]["klasika"]

    titles = [b["title"] for b in body["booked"]]
    assert "Future Concert" in titles
    assert "Past Concert" not in titles

    assert body["digest_week"].startswith("CW")

    # No Discogs token configured in tests → the lane is a soft-missing source.
    assert body["discogs"] is None


@pytest.mark.asyncio
async def test_digest_context_feedback_sentiment(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    await login_as(client, "petr@example.com")
    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None

    for rating, title in [
        (FeedbackRating.UP, "Liked A"),
        (FeedbackRating.UP, "Liked B"),
        (FeedbackRating.DOWN, "Disliked C"),
    ]:
        db_session.add(
            RecommendationFeedback(
                id=uuid7(),
                event_title=title,
                event_lane="klasika",
                digest_week="CW21",
                rating=rating,
            )
        )
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_DIGEST_READ]
    )
    await db_session.commit()

    response = await client.get("/v1/digest/context", headers=auth_header(pat))
    assert response.status_code == 200, response.text
    feedback = response.json()["feedback"]

    klasika = feedback["lane_sentiment"]["klasika"]
    assert klasika["ups"] == 2
    assert klasika["downs"] == 1
    # 1.0 + 0.1 * (2 - 1) = 1.1
    assert klasika["multiplier"] == pytest.approx(1.1)
    assert "Disliked C" in feedback["recent_downvoted_titles"]


@pytest.mark.asyncio
async def test_digest_context_includes_discogs_taste(
    client: AsyncClient, settings: Settings, db_session: AsyncSession
) -> None:
    await login_as(client, "petr@example.com")
    user = await db_session.scalar(select(User).where(User.email == "petr@example.com"))
    assert user is not None
    pat = await mint_pat(
        db_session, user, name="routine", settings=settings, scopes=[SCOPE_DIGEST_READ]
    )
    await db_session.commit()

    taste = DiscogsTaste(
        username="petronijus",
        release_count=1,
        artists=["Gustav Mahler"],
        releases=[DiscogsRelease(title="Symphony No. 5", artists=["Gustav Mahler"], year=1985)],
    )
    app.dependency_overrides[provide_discogs_taste] = lambda: taste
    try:
        response = await client.get("/v1/digest/context", headers=auth_header(pat))
    finally:
        app.dependency_overrides.pop(provide_discogs_taste, None)

    assert response.status_code == 200, response.text
    discogs = response.json()["discogs"]
    assert discogs["username"] == "petronijus"
    assert discogs["artists"] == ["Gustav Mahler"]
    assert discogs["releases"][0]["title"] == "Symphony No. 5"
