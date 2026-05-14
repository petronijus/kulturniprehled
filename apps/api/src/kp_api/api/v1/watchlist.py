"""Watchlist REST endpoints.

Items live in the shared workspace and nest one level: a row whose
`parent_id` is non-NULL is a child, and that parent must itself have
`parent_id IS NULL`. The depth cap is enforced here, not in SQL.

Position handling uses fractional ranks: a float is interpolated between
the two neighbours on every insert/move, so only the moved row changes
and the index stays usable. The very small risk of running out of float
precision after thousands of mid-point inserts at the same gap is
acceptable for a household-scale list; if it ever bites we can renumber
the scope in a single UPDATE.
"""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.api.deps import CurrentUser, SessionDep
from kp_api.domain.enums import ChangeOp
from kp_api.domain.models import User, WatchlistItem, Workspace, WorkspaceMember
from kp_api.domain.schemas import (
    WatchlistCheckRequest,
    WatchlistItemCreate,
    WatchlistItemResponse,
    WatchlistItemUpdate,
    WatchlistListResponse,
    WatchlistMoveRequest,
)
from kp_api.sync.changelog import record_watchlist_change

router = APIRouter(prefix="/v1/watchlist", tags=["watchlist"])


def _utcnow() -> datetime:
    return datetime.now(UTC)


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


async def _get_active(session: AsyncSession, workspace: Workspace, item_id: UUID) -> WatchlistItem:
    item = await session.scalar(
        select(WatchlistItem).where(
            WatchlistItem.id == item_id,
            WatchlistItem.workspace_id == workspace.id,
            WatchlistItem.deleted_at.is_(None),
        )
    )
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "watchlist item not found")
    return item


async def _validate_parent(
    session: AsyncSession, workspace: Workspace, parent_id: UUID
) -> WatchlistItem:
    parent = await _get_active(session, workspace, parent_id)
    if parent.parent_id is not None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            {"code": "max_depth_exceeded", "detail": "watchlist nests one level only"},
        )
    return parent


async def _scope_max_position(
    session: AsyncSession, workspace: Workspace, parent_id: UUID | None
) -> float | None:
    stmt = select(WatchlistItem.position).where(
        WatchlistItem.workspace_id == workspace.id,
        WatchlistItem.deleted_at.is_(None),
    )
    if parent_id is None:
        stmt = stmt.where(WatchlistItem.parent_id.is_(None))
    else:
        stmt = stmt.where(WatchlistItem.parent_id == parent_id)
    stmt = stmt.order_by(WatchlistItem.position.desc()).limit(1)
    result: float | None = await session.scalar(stmt)
    return result


async def _scope_min_position(
    session: AsyncSession, workspace: Workspace, parent_id: UUID | None
) -> float | None:
    stmt = select(WatchlistItem.position).where(
        WatchlistItem.workspace_id == workspace.id,
        WatchlistItem.deleted_at.is_(None),
    )
    if parent_id is None:
        stmt = stmt.where(WatchlistItem.parent_id.is_(None))
    else:
        stmt = stmt.where(WatchlistItem.parent_id == parent_id)
    stmt = stmt.order_by(WatchlistItem.position.asc()).limit(1)
    result: float | None = await session.scalar(stmt)
    return result


async def _neighbour_position(
    session: AsyncSession,
    workspace: Workspace,
    parent_id: UUID | None,
    relative_to: float,
    direction: str,
    exclude_id: UUID | None = None,
) -> float | None:
    """Return the position immediately before/after `relative_to` in the same
    scope, or None if `relative_to` is at the edge. `direction` is `"before"`
    (lower position) or `"after"` (higher position).
    """

    stmt = select(WatchlistItem.position).where(
        WatchlistItem.workspace_id == workspace.id,
        WatchlistItem.deleted_at.is_(None),
    )
    if parent_id is None:
        stmt = stmt.where(WatchlistItem.parent_id.is_(None))
    else:
        stmt = stmt.where(WatchlistItem.parent_id == parent_id)
    if exclude_id is not None:
        stmt = stmt.where(WatchlistItem.id != exclude_id)
    if direction == "before":
        stmt = stmt.where(WatchlistItem.position < relative_to).order_by(
            WatchlistItem.position.desc()
        )
    else:
        stmt = stmt.where(WatchlistItem.position > relative_to).order_by(
            WatchlistItem.position.asc()
        )
    result: float | None = await session.scalar(stmt.limit(1))
    return result


async def _compute_position(
    session: AsyncSession,
    workspace: Workspace,
    parent_id: UUID | None,
    *,
    after_id: UUID | None,
    before_id: UUID | None,
    to_end: bool = False,
    moving_id: UUID | None = None,
) -> float:
    """Pick a float position inside (`parent_id` scope).

    - `after_id` / `before_id` are anchors — the new position sits between
      the anchor and its existing neighbour.
    - `to_end` appends at the end of the scope.
    - Default behaviour (all flags falsy) appends at the end.
    - `moving_id`, when set, is excluded from neighbour lookups so a move
      between adjacent siblings still finds a new midpoint.
    """

    if after_id is not None and before_id is not None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "specify only one of after_id / before_id",
        )

    if after_id is not None:
        anchor = await _get_active(session, workspace, after_id)
        if anchor.parent_id != parent_id:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "after_id belongs to a different parent scope",
            )
        next_pos = await _neighbour_position(
            session,
            workspace,
            parent_id,
            anchor.position,
            "after",
            exclude_id=moving_id,
        )
        return (anchor.position + next_pos) / 2 if next_pos is not None else anchor.position + 1.0

    if before_id is not None:
        anchor = await _get_active(session, workspace, before_id)
        if anchor.parent_id != parent_id:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "before_id belongs to a different parent scope",
            )
        prev_pos = await _neighbour_position(
            session,
            workspace,
            parent_id,
            anchor.position,
            "before",
            exclude_id=moving_id,
        )
        return (prev_pos + anchor.position) / 2 if prev_pos is not None else anchor.position - 1.0

    # to_end is the implicit default — also the fallback when both anchors absent.
    _ = to_end
    max_pos = await _scope_max_position(session, workspace, parent_id)
    return (max_pos + 1.0) if max_pos is not None else 1.0


@router.get("", response_model=WatchlistListResponse)
async def list_items(
    session: SessionDep,
    user: CurrentUser,
) -> WatchlistListResponse:
    workspace = await _user_workspace(session, user)
    rows = await session.scalars(
        select(WatchlistItem).where(
            WatchlistItem.workspace_id == workspace.id,
            WatchlistItem.deleted_at.is_(None),
        )
        # NULLS FIRST so roots come before children of any particular parent;
        # the client groups by parent_id and reads `position` for in-scope order.
        .order_by(WatchlistItem.parent_id.asc().nulls_first(), WatchlistItem.position.asc())
    )
    return WatchlistListResponse(
        items=[WatchlistItemResponse.model_validate(r) for r in rows.all()]
    )


@router.post("", response_model=WatchlistItemResponse, status_code=status.HTTP_201_CREATED)
async def create_item(
    body: WatchlistItemCreate,
    session: SessionDep,
    user: CurrentUser,
) -> WatchlistItemResponse:
    workspace = await _user_workspace(session, user)
    if body.parent_id is not None:
        await _validate_parent(session, workspace, body.parent_id)

    position = await _compute_position(
        session,
        workspace,
        body.parent_id,
        after_id=body.after_id,
        before_id=body.before_id,
    )
    item = WatchlistItem(
        workspace_id=workspace.id,
        parent_id=body.parent_id,
        title=body.title,
        kind=body.kind,
        note=body.note,
        position=position,
        created_by=user.id,
        version=1,
    )
    session.add(item)
    await session.flush()
    await record_watchlist_change(session, item, user.id, ChangeOp.UPSERT)
    await session.commit()
    await session.refresh(item)
    return WatchlistItemResponse.model_validate(item)


@router.patch("/{item_id}", response_model=WatchlistItemResponse)
async def update_item(
    item_id: UUID,
    body: WatchlistItemUpdate,
    session: SessionDep,
    user: CurrentUser,
) -> WatchlistItemResponse:
    workspace = await _user_workspace(session, user)
    item = await _get_active(session, workspace, item_id)
    if item.version != body.version:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            {"code": "version_mismatch", "current_version": item.version},
        )
    data = body.model_dump(exclude_unset=True, exclude={"version"})
    for key, value in data.items():
        setattr(item, key, value)
    item.version += 1
    await session.flush()
    await record_watchlist_change(session, item, user.id, ChangeOp.UPSERT)
    await session.commit()
    await session.refresh(item)
    return WatchlistItemResponse.model_validate(item)


@router.post("/{item_id}/check", response_model=WatchlistItemResponse)
async def check_item(
    item_id: UUID,
    body: WatchlistCheckRequest,
    session: SessionDep,
    user: CurrentUser,
) -> WatchlistItemResponse:
    workspace = await _user_workspace(session, user)
    item = await _get_active(session, workspace, item_id)
    if item.version != body.version:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            {"code": "version_mismatch", "current_version": item.version},
        )
    if item.done == body.done:
        # No-op — return current state; do not bump version or emit a
        # change_log row so spamming the checkbox stays cheap.
        return WatchlistItemResponse.model_validate(item)

    item.done = body.done
    if body.done:
        item.done_at = _utcnow()
        item.done_by = user.id
    else:
        item.done_at = None
        item.done_by = None
    item.version += 1
    await session.flush()
    await record_watchlist_change(session, item, user.id, ChangeOp.UPSERT)
    await session.commit()
    await session.refresh(item)
    return WatchlistItemResponse.model_validate(item)


@router.post("/{item_id}/move", response_model=WatchlistItemResponse)
async def move_item(
    item_id: UUID,
    body: WatchlistMoveRequest,
    session: SessionDep,
    user: CurrentUser,
) -> WatchlistItemResponse:
    workspace = await _user_workspace(session, user)
    item = await _get_active(session, workspace, item_id)
    if item.version != body.version:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            {"code": "version_mismatch", "current_version": item.version},
        )

    new_parent_id = body.parent_id if body.set_parent else item.parent_id
    if new_parent_id is not None:
        # Reparenting an item that itself has children would create a 3-level
        # tree — refuse. The mobile UI should also prevent this.
        if new_parent_id == item.id:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "cannot make an item its own parent",
            )
        await _validate_parent(session, workspace, new_parent_id)
        has_children = await session.scalar(
            select(WatchlistItem.id)
            .where(
                WatchlistItem.parent_id == item.id,
                WatchlistItem.deleted_at.is_(None),
            )
            .limit(1)
        )
        if has_children is not None:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                {
                    "code": "max_depth_exceeded",
                    "detail": "cannot move a parent item under another parent",
                },
            )

    new_position = await _compute_position(
        session,
        workspace,
        new_parent_id,
        after_id=body.after_id,
        before_id=body.before_id,
        to_end=body.to_end,
        moving_id=item.id,
    )

    item.parent_id = new_parent_id
    item.position = new_position
    item.version += 1
    await session.flush()
    await record_watchlist_change(session, item, user.id, ChangeOp.UPSERT)
    await session.commit()
    await session.refresh(item)
    return WatchlistItemResponse.model_validate(item)


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_item(
    item_id: UUID,
    session: SessionDep,
    user: CurrentUser,
) -> Response:
    workspace = await _user_workspace(session, user)
    item = await _get_active(session, workspace, item_id)

    now = _utcnow()
    # Soft-delete the parent and every direct child in the same transaction,
    # emitting a change_log row per row so each client side can drop them
    # independently on next sync.
    if item.parent_id is None:
        children = (
            await session.scalars(
                select(WatchlistItem).where(
                    WatchlistItem.workspace_id == workspace.id,
                    WatchlistItem.parent_id == item.id,
                    WatchlistItem.deleted_at.is_(None),
                )
            )
        ).all()
        for child in children:
            child.deleted_at = now
            child.version += 1
            await session.flush()
            await record_watchlist_change(session, child, user.id, ChangeOp.DELETE)

    item.deleted_at = now
    item.version += 1
    await session.flush()
    await record_watchlist_change(session, item, user.id, ChangeOp.DELETE)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


__all__ = ["router"]
