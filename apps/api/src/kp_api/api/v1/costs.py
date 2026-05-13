"""Costs endpoints.

Costs hang off events: every line is created via
`POST /v1/events/{event_id}/costs`. Listings are workspace-wide via
`GET /v1/events/{event_id}/costs`. Mutations follow the same optimistic-
locking + change_log pattern used for events.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.fx import FrankfurterProvider, FxRateProvider, convert
from kp_api.api.deps import CurrentUser, SessionDep
from kp_api.domain.enums import ChangeOp
from kp_api.domain.models import Cost, Event, User, Workspace, WorkspaceMember
from kp_api.domain.schemas import (
    CostCreate,
    CostListResponse,
    CostResponse,
    CostUpdate,
)
from kp_api.sync.changelog import record_cost_change

router = APIRouter(prefix="/v1/costs", tags=["costs"])
events_router = APIRouter(prefix="/v1/events", tags=["costs"])

# Dependency hook so tests can swap in a deterministic provider.
_fx_provider: FxRateProvider | None = None


def set_fx_provider(provider: FxRateProvider | None) -> None:
    global _fx_provider
    _fx_provider = provider


def _provider() -> FxRateProvider:
    return _fx_provider or FrankfurterProvider()


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


async def _user_workspace(session: AsyncSession, user: User) -> Workspace:
    workspace = await session.scalar(
        select(Workspace)
        .join(WorkspaceMember, WorkspaceMember.workspace_id == Workspace.id)
        .where(WorkspaceMember.user_id == user.id)
        .limit(1)
    )
    if workspace is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "user has no workspace")
    return workspace


async def _event_in_workspace(
    session: AsyncSession, workspace: Workspace, event_id: UUID
) -> Event:
    event = await session.scalar(
        select(Event).where(
            Event.id == event_id,
            Event.workspace_id == workspace.id,
            Event.deleted_at.is_(None),
        )
    )
    if event is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "event not found")
    return event


async def _cost_in_workspace(
    session: AsyncSession, workspace: Workspace, cost_id: UUID
) -> Cost:
    cost = await session.scalar(
        select(Cost).where(
            Cost.id == cost_id,
            Cost.workspace_id == workspace.id,
            Cost.deleted_at.is_(None),
        )
    )
    if cost is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "cost not found")
    return cost


@events_router.post(
    "/{event_id}/costs",
    response_model=CostResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_cost(
    event_id: UUID,
    body: CostCreate,
    session: SessionDep,
    user: CurrentUser,
) -> CostResponse:
    workspace = await _user_workspace(session, user)
    event = await _event_in_workspace(session, workspace, event_id)
    cost = Cost(
        event_id=event.id,
        workspace_id=workspace.id,
        amount_cents=body.amount_cents,
        currency=body.currency.upper(),
        kind=body.kind,
        paid_by=body.paid_by or user.id,
        split=body.split,
        note=body.note,
        paid_at=body.paid_at,
        version=1,
    )
    session.add(cost)
    await session.flush()
    await record_cost_change(session, cost, user.id, ChangeOp.UPSERT)
    await session.commit()
    await session.refresh(cost)
    return CostResponse.model_validate(cost)


@events_router.get(
    "/{event_id}/costs",
    response_model=CostListResponse,
)
async def list_event_costs(
    event_id: UUID,
    session: SessionDep,
    user: CurrentUser,
    primary: Annotated[str, "query"] = "CZK",
) -> CostListResponse:
    workspace = await _user_workspace(session, user)
    await _event_in_workspace(session, workspace, event_id)
    rows = (
        await session.scalars(
            select(Cost)
            .where(
                Cost.event_id == event_id,
                Cost.workspace_id == workspace.id,
                Cost.deleted_at.is_(None),
            )
            .order_by(Cost.paid_at.asc())
        )
    ).all()

    primary = primary.upper()
    provider = _provider()
    total = 0
    for cost in rows:
        total += await convert(
            session,
            provider,
            amount_cents=cost.amount_cents,
            currency=cost.currency,
            on=cost.paid_at,
            target=primary,
        )
    await session.commit()  # persist any newly-cached FX rates
    return CostListResponse(
        items=[CostResponse.model_validate(c) for c in rows],
        total_in_primary_currency=total,
        primary_currency=primary,
    )


@router.patch("/{cost_id}", response_model=CostResponse)
async def update_cost(
    cost_id: UUID,
    body: CostUpdate,
    session: SessionDep,
    user: CurrentUser,
) -> CostResponse:
    workspace = await _user_workspace(session, user)
    cost = await _cost_in_workspace(session, workspace, cost_id)
    if cost.version != body.version:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            {"code": "version_mismatch", "current_version": cost.version},
        )
    data = body.model_dump(exclude_unset=True, exclude={"version"})
    if "currency" in data and isinstance(data["currency"], str):
        data["currency"] = data["currency"].upper()
    for key, value in data.items():
        setattr(cost, key, value)
    cost.version += 1
    await session.flush()
    await record_cost_change(session, cost, user.id, ChangeOp.UPSERT)
    await session.commit()
    await session.refresh(cost)
    return CostResponse.model_validate(cost)


@router.delete("/{cost_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_cost(
    cost_id: UUID,
    session: SessionDep,
    user: CurrentUser,
) -> Response:
    workspace = await _user_workspace(session, user)
    cost = await _cost_in_workspace(session, workspace, cost_id)
    cost.deleted_at = _utcnow()
    cost.version += 1
    await session.flush()
    await record_cost_change(session, cost, user.id, ChangeOp.DELETE)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
