"""Stats endpoint — aggregated counts and CZK totals for a year.

All money is in CZK haléře (`amount_cents`) — multi-currency was dropped
in 0006. Aggregation is therefore a single SQL pass.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import distinct, func, select
from sqlalchemy.ext.asyncio import AsyncSession

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


async def _user_workspace(session: AsyncSession, user: User) -> Workspace:
    workspace = await session.scalar(
        select(Workspace)
        .join(WorkspaceMember, WorkspaceMember.workspace_id == Workspace.id)
        .where(WorkspaceMember.user_id == user.id)
        .limit(1)
    )
    assert workspace is not None
    return workspace


@router.get("", response_model=StatsResponse)
async def stats(
    session: SessionDep,
    user: CurrentUser,
    year: Annotated[int, Query(ge=2000, le=2100)],
) -> StatsResponse:
    workspace = await _user_workspace(session, user)

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
        StatsByCategory(category=EventCategory(row[0]), count=int(row[1])) for row in by_cat_rows
    ]
    total_events = sum(c.count for c in by_category)

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

    by_month_cost_rows = (
        await session.execute(
            select(
                func.extract("month", Cost.paid_at).label("month"),
                func.coalesce(func.sum(Cost.amount_cents), 0).label("total"),
            )
            .where(
                Cost.workspace_id == workspace.id,
                Cost.deleted_at.is_(None),
                func.extract("year", Cost.paid_at) == year,
            )
            .group_by(func.extract("month", Cost.paid_at))
        )
    ).all()
    by_month_cost = {int(row[0]): int(row[1]) for row in by_month_cost_rows}
    total_cost = sum(by_month_cost.values())

    by_month = [
        StatsByMonth(
            month=m,
            events=by_month_events.get(m, 0),
            total_cost_cents=by_month_cost.get(m, 0),
        )
        for m in range(1, 13)
        if by_month_events.get(m, 0) > 0 or by_month_cost.get(m, 0) > 0
    ]

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
    top_venues = [StatsTopVenue(name=str(row[0]), count=int(row[1])) for row in venue_rows]

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

    return StatsResponse(
        year=year,
        total_events=total_events,
        attended=int(attended or 0),
        upcoming=int(upcoming or 0),
        by_category=by_category,
        by_month=by_month,
        top_venues=top_venues,
        total_cost_cents=total_cost,
    )
