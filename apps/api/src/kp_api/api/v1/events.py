"""CRUD endpoints for events.

The model uses a single shared workspace (Petr + Běla), so the user's
workspace is resolved from `WorkspaceMember` and every event lives in that
workspace. Optimistic locking is enforced on PATCH: clients must send the
last-seen `version`, and the server returns 409 on mismatch.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Response, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.api.deps import CurrentUser, SessionDep
from kp_api.domain.enums import EventCategory, EventSource, EventStatus
from kp_api.domain.models import Event, User, Workspace, WorkspaceMember
from kp_api.domain.schemas import (
    EventCreate,
    EventListResponse,
    EventResponse,
    EventUpdate,
)

router = APIRouter(prefix="/v1/events", tags=["events"])


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


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


@router.get("", response_model=EventListResponse)
async def list_events(
    session: SessionDep,
    user: CurrentUser,
    starts_from: Annotated[datetime | None, Query()] = None,
    starts_to: Annotated[datetime | None, Query()] = None,
    category: Annotated[EventCategory | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> EventListResponse:
    workspace = await _user_workspace(session, user)
    base = select(Event).where(
        Event.workspace_id == workspace.id,
        Event.deleted_at.is_(None),
    )
    if starts_from is not None:
        base = base.where(Event.starts_at >= starts_from)
    if starts_to is not None:
        base = base.where(Event.starts_at < starts_to)
    if category is not None:
        base = base.where(Event.category == category)

    total = await session.scalar(
        select(func.count()).select_from(base.subquery())
    )
    rows = await session.scalars(
        base.order_by(Event.starts_at.asc()).offset(offset).limit(limit)
    )
    return EventListResponse(
        items=[EventResponse.model_validate(e) for e in rows.all()],
        total=int(total or 0),
    )


@router.post("", response_model=EventResponse, status_code=status.HTTP_201_CREATED)
async def create_event(
    body: EventCreate,
    session: SessionDep,
    user: CurrentUser,
) -> EventResponse:
    workspace = await _user_workspace(session, user)
    event = Event(
        workspace_id=workspace.id,
        title=body.title,
        category=body.category,
        venue_id=body.venue_id,
        starts_at=body.starts_at,
        ends_at=body.ends_at,
        venue_timezone=body.venue_timezone,
        status=body.status,
        source=body.source,
        notes=body.notes,
        created_by=user.id,
        version=1,
    )
    session.add(event)
    await session.commit()
    await session.refresh(event)
    return EventResponse.model_validate(event)


async def _get_active_event(
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


@router.get("/{event_id}", response_model=EventResponse)
async def get_event(
    event_id: UUID,
    session: SessionDep,
    user: CurrentUser,
) -> EventResponse:
    workspace = await _user_workspace(session, user)
    event = await _get_active_event(session, workspace, event_id)
    return EventResponse.model_validate(event)


@router.patch("/{event_id}", response_model=EventResponse)
async def update_event(
    event_id: UUID,
    body: EventUpdate,
    session: SessionDep,
    user: CurrentUser,
) -> EventResponse:
    workspace = await _user_workspace(session, user)
    event = await _get_active_event(session, workspace, event_id)
    if event.version != body.version:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            {"code": "version_mismatch", "current_version": event.version},
        )
    data = body.model_dump(exclude_unset=True, exclude={"version"})
    for key, value in data.items():
        setattr(event, key, value)
    event.version += 1
    await session.commit()
    await session.refresh(event)
    return EventResponse.model_validate(event)


@router.delete("/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_event(
    event_id: UUID,
    session: SessionDep,
    user: CurrentUser,
) -> Response:
    workspace = await _user_workspace(session, user)
    event = await _get_active_event(session, workspace, event_id)
    event.deleted_at = _utcnow()
    event.version += 1
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# Re-export to make the router list explicit in main.
__all__ = ["router", "EventCategory", "EventSource", "EventStatus"]
