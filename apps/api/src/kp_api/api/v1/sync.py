"""Sync API endpoints — `GET /v1/sync` for pulls, `POST /v1/sync/apply` for outbox."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.api.deps import CurrentUser, SessionDep
from kp_api.domain.models import User, Workspace, WorkspaceMember
from kp_api.sync.schemas import ApplyRequest, ApplyResponse, ChangesPage
from kp_api.sync.service import apply_operations, fetch_changes

router = APIRouter(prefix="/v1/sync", tags=["sync"])


async def _user_workspace(session: AsyncSession, user: User) -> Workspace:
    workspace = await session.scalar(
        select(Workspace)
        .join(WorkspaceMember, WorkspaceMember.workspace_id == Workspace.id)
        .where(WorkspaceMember.user_id == user.id)
        .limit(1)
    )
    assert workspace is not None  # noqa: S101 — endpoint requires CurrentUser
    return workspace


@router.get("", response_model=ChangesPage)
async def get_changes(
    session: SessionDep,
    user: CurrentUser,
    since: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
) -> ChangesPage:
    workspace = await _user_workspace(session, user)
    return await fetch_changes(session, workspace, since=since, limit=limit)


@router.post("/apply", response_model=ApplyResponse)
async def post_apply(
    body: ApplyRequest,
    session: SessionDep,
    user: CurrentUser,
) -> ApplyResponse:
    workspace = await _user_workspace(session, user)
    response = await apply_operations(session, user, workspace, body.operations)
    await session.commit()
    return response
