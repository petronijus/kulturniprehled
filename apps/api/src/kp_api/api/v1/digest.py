"""Weekly-digest context endpoint.

Precomputes everything the cloud culture routine used to assemble by hand
from raw `/v1/events` + `/v1/feedback/history` (the balance signal, the
booked-event list for spacing/dedup, the per-lane feedback sentiment). Doing
it server-side means the routine holds a single narrow `digest:read` scope
instead of general event-read access, and the routine prompt drops all the
`jq`/`date` arithmetic.

Lane → category mapping (a lane is a domain expert; several map to the same
KP event category):

    klasika, elektronika → concert
    divadlo              → theatre
    film                 → cinema
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.discogs import DiscogsTaste, fetch_discogs_taste
from kp_api.api.deps import SessionDep, SettingsDep, require_scope
from kp_api.domain.enums import EventCategory, FeedbackRating
from kp_api.domain.models import Event, RecommendationFeedback, User, Workspace, WorkspaceMember
from kp_api.domain.scopes import SCOPE_DIGEST_READ

router = APIRouter(prefix="/v1/digest", tags=["digest"])

# A lane is what a domain-expert skill produces; the balance signal is tracked
# per KP event category, so several lanes share one category's recency.
LANE_CATEGORY: dict[str, EventCategory] = {
    "klasika": EventCategory.CONCERT,
    "elektronika": EventCategory.CONCERT,
    "divadlo": EventCategory.THEATRE,
    "film": EventCategory.CINEMA,
}


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def _balance_multiplier(days_since: int) -> float:
    """Lean into a neglected lane, damp a recently-served one.

    `1.0 + (days_since - 30) / 60`, clamped to 0.5-1.8: a concert 5 days ago
    pulls further concerts down to ~0.6, one 60 days ago lifts them to ~1.5."""

    return round(_clamp(1.0 + (days_since - 30) / 60, 0.5, 1.8), 3)


def _feedback_multiplier(ups: int, downs: int) -> float:
    """`1.0 + 0.1 * (ups - downs)`, clamped to 0.6-1.4."""

    return round(_clamp(1.0 + 0.1 * (ups - downs), 0.6, 1.4), 3)


class BalanceSignal(BaseModel):
    days_since: dict[str, int]
    multiplier: dict[str, float]
    hint: str


class BookedEvent(BaseModel):
    title: str
    starts_at: datetime
    category: EventCategory


class LaneSentiment(BaseModel):
    ups: int
    downs: int
    multiplier: float


class FeedbackSignal(BaseModel):
    lane_sentiment: dict[str, LaneSentiment]
    recent_downvoted_titles: list[str]


class DigestContextResponse(BaseModel):
    now: datetime
    iso_week: str
    digest_week: str
    horizon_days: int
    lookback_days: int
    balance: BalanceSignal
    booked: list[BookedEvent]
    feedback: FeedbackSignal
    # Long-term taste anchor for the klasika lane. `null` when no Discogs
    # token is configured or Discogs is unreachable — a soft-missing source.
    discogs: DiscogsTaste | None = None


async def provide_discogs_taste(settings: SettingsDep) -> DiscogsTaste | None:
    """Dependency wrapper so tests can override the (networked) fetch."""

    return await fetch_discogs_taste(settings.discogs_token, settings.discogs_username)


async def _user_workspace(session: AsyncSession, user: User) -> Workspace:
    workspace = await session.scalar(
        select(Workspace)
        .join(WorkspaceMember, WorkspaceMember.workspace_id == Workspace.id)
        .where(WorkspaceMember.user_id == user.id)
        .limit(1)
    )
    assert workspace is not None
    return workspace


@router.get("/context", response_model=DigestContextResponse)
async def digest_context(
    session: SessionDep,
    user: Annotated[User, Depends(require_scope(SCOPE_DIGEST_READ))],
    discogs: Annotated[DiscogsTaste | None, Depends(provide_discogs_taste)],
    horizon_days: Annotated[int, Query(ge=1, le=365)] = 180,
    lookback_days: Annotated[int, Query(ge=1, le=365)] = 180,
) -> DigestContextResponse:
    workspace = await _user_workspace(session, user)
    now = datetime.now(UTC)
    horizon = now + timedelta(days=horizon_days)
    lookback = now - timedelta(days=lookback_days)
    fb_window = now - timedelta(days=90)

    # Balance signal: days since the most recent past event of each category.
    days_since: dict[str, int] = {}
    for category in (EventCategory.CONCERT, EventCategory.THEATRE, EventCategory.CINEMA):
        last = await session.scalar(
            select(Event.starts_at)
            .where(
                Event.workspace_id == workspace.id,
                Event.deleted_at.is_(None),
                Event.category == category,
                Event.starts_at >= lookback,
                Event.starts_at <= now,
            )
            .order_by(Event.starts_at.desc())
            .limit(1)
        )
        days_since[category.value] = 999 if last is None else (now - last).days

    multiplier = {
        lane: _balance_multiplier(days_since[cat.value]) for lane, cat in LANE_CATEGORY.items()
    }
    hint = (
        f"{days_since['concert']} dní bez koncertu, "
        f"{days_since['theatre']} bez divadla, "
        f"{days_since['cinema']} bez kina"
    )

    # Booked events ahead — drives the spacing rule and the experts' dedup.
    booked_rows = await session.scalars(
        select(Event)
        .where(
            Event.workspace_id == workspace.id,
            Event.deleted_at.is_(None),
            Event.starts_at >= now,
            Event.starts_at <= horizon,
        )
        .order_by(Event.starts_at.asc())
    )
    booked = [
        BookedEvent(title=e.title, starts_at=e.starts_at, category=e.category)
        for e in booked_rows.all()
    ]

    # Feedback sentiment over the last 90 days, per lane.
    fb_rows = (
        await session.scalars(
            select(RecommendationFeedback).where(
                RecommendationFeedback.created_at >= fb_window,
            )
        )
    ).all()
    counts: dict[str, dict[str, int]] = {}
    downvoted: list[str] = []
    for fb in fb_rows:
        bucket = counts.setdefault(fb.event_lane, {"ups": 0, "downs": 0})
        if fb.rating == FeedbackRating.UP:
            bucket["ups"] += 1
        else:
            bucket["downs"] += 1
            if fb.event_title not in downvoted:
                downvoted.append(fb.event_title)
    lane_sentiment = {
        lane: LaneSentiment(
            ups=c["ups"],
            downs=c["downs"],
            multiplier=_feedback_multiplier(c["ups"], c["downs"]),
        )
        for lane, c in counts.items()
    }

    return DigestContextResponse(
        now=now,
        iso_week=now.strftime("%G-W%V"),
        digest_week=f"CW{now.strftime('%V')}",
        horizon_days=horizon_days,
        lookback_days=lookback_days,
        balance=BalanceSignal(days_since=days_since, multiplier=multiplier, hint=hint),
        booked=booked,
        feedback=FeedbackSignal(lane_sentiment=lane_sentiment, recent_downvoted_titles=downvoted),
        discogs=discogs,
    )
