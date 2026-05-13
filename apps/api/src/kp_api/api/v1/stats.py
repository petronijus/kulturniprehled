"""Stats endpoint — aggregated counts and converted totals for a year.

Two passes over the workspace's data:
1. Pure SQL aggregates (events per month/category/status, venue tallies).
2. Cost rows fetched and converted to the primary currency via the FX
   provider so totals stay reproducible even after a frankfurter dataset
   rotation.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import distinct, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.fx import FrankfurterProvider, FxRateProvider, convert
from kp_api.api.deps import CurrentUser, SessionDep
from kp_api.domain.enums import EventCategory, EventStatus
from kp_api.domain.models import Cost, Event, User, Venue, Workspace, WorkspaceMember
from kp_api.domain.schemas import (
    StatsByCategory,
    StatsByMonth,
    StatsResponse,
    StatsTopVenue,
)

router = APIRouter(prefix="/v1/stats", tags=["stats"])

_fx_provider: FxRateProvider | None = None


def set_fx_provider(provider: FxRateProvider | None) -> None:
    global _fx_provider
    _fx_provider = provider


def _provider() -> FxRateProvider:
    return _fx_provider or FrankfurterProvider()


async def _user_workspace(session: AsyncSession, user: User) -> Workspace:
    workspace = await session.scalar(
        select(Workspace)
        .join(WorkspaceMember, WorkspaceMember.workspace_id == Workspace.id)
        .where(WorkspaceMember.user_id == user.id)
        .limit(1)
    )
    assert workspace is not None  # noqa: S101 — CurrentUser guarantees this
    return workspace


@router.get("", response_model=StatsResponse)
async def stats(
    session: SessionDep,
    user: CurrentUser,
    year: Annotated[int, Query(ge=2000, le=2100)],
    primary: Annotated[str, Query()] = "CZK",
) -> StatsResponse:
    workspace = await _user_workspace(session, user)

    # ---- Events per category ----
    by_cat_rows = (
        await session.execute(
            select(Event.category, func.count())
            .where(
                Event.workspace_id == workspace.id,
                Event.deleted_at.is_(None),
                func.extract("year", Event.starts_at) == year,
            )
            .group_by(Event.category)
        )
    ).all()

    by_category = [
        StatsByCategory(category=EventCategory(row[0]), count=int(row[1]))
        for row in by_cat_rows
    ]
    total_events = sum(c.count for c in by_category)

    # ---- Events per month ----
    by_month_rows = (
        await session.execute(
            select(
                func.extract("month", Event.starts_at).label("month"),
                func.count().label("events"),
            )
            .where(
                Event.workspace_id == workspace.id,
                Event.deleted_at.is_(None),
                func.extract("year", Event.starts_at) == year,
            )
            .group_by(func.extract("month", Event.starts_at))
            .order_by(func.extract("month", Event.starts_at))
        )
    ).all()
    by_month_events = {int(row[0]): int(row[1]) for row in by_month_rows}

    # ---- Cost rollups (per month and total) ----
    costs = (
        await session.scalars(
            select(Cost).where(
                Cost.workspace_id == workspace.id,
                Cost.deleted_at.is_(None),
                func.extract("year", Cost.paid_at) == year,
            )
        )
    ).all()
    primary = primary.upper()
    provider = _provider()
    by_month_cost: dict[int, int] = {}
    total_cost = 0
    for cost in costs:
        converted = await convert(
            session,
            provider,
            amount_cents=cost.amount_cents,
            currency=cost.currency,
            on=cost.paid_at,
            target=primary,
        )
        by_month_cost[cost.paid_at.month] = (
            by_month_cost.get(cost.paid_at.month, 0) + converted
        )
        total_cost += converted

    by_month = [
        StatsByMonth(
            month=m,
            events=by_month_events.get(m, 0),
            total_cost_cents=by_month_cost.get(m, 0),
        )
        for m in range(1, 13)
        if by_month_events.get(m, 0) > 0 or by_month_cost.get(m, 0) > 0
    ]

    # ---- Top venues (by event count) ----
    venue_rows = (
        await session.execute(
            select(Venue.name, func.count())
            .join(Event, Event.venue_id == Venue.id)
            .where(
                Event.workspace_id == workspace.id,
                Event.deleted_at.is_(None),
                func.extract("year", Event.starts_at) == year,
            )
            .group_by(Venue.name)
            .order_by(func.count().desc())
            .limit(5)
        )
    ).all()
    top_venues = [
        StatsTopVenue(name=str(row[0]), count=int(row[1])) for row in venue_rows
    ]

    # ---- Attended / upcoming counters ----
    attended = await session.scalar(
        select(func.count(distinct(Event.id))).where(
            Event.workspace_id == workspace.id,
            Event.deleted_at.is_(None),
            func.extract("year", Event.starts_at) == year,
            Event.status == EventStatus.ATTENDED,
        )
    )
    upcoming = await session.scalar(
        select(func.count(distinct(Event.id))).where(
            Event.workspace_id == workspace.id,
            Event.deleted_at.is_(None),
            func.extract("year", Event.starts_at) == year,
            Event.status == EventStatus.PLANNED,
        )
    )

    await session.commit()  # persist FX cache writes done during the loop

    return StatsResponse(
        year=year,
        total_events=total_events,
        attended=int(attended or 0),
        upcoming=int(upcoming or 0),
        by_category=by_category,
        by_month=by_month,
        top_venues=top_venues,
        total_cost_cents=total_cost,
        primary_currency=primary,
    )
