"""Sync service: pull `change_log` deltas and apply outbox batches.

`fetch_changes` is a plain windowed read over `change_log` scoped to the
caller's workspace. `apply_operations` consumes a client outbox: every
operation runs inside its own SAVEPOINT so a single failure does not poison
the whole batch, and every operation is recorded in `applied_ops` keyed by
`op_id` so a flaky network never produces a duplicate event.

Idempotency contract:
- The first apply of an `op_id` returns the canonical result and caches it.
- A retry of the same `op_id` returns the cached result verbatim regardless
  of subsequent state — this matches Stripe-style idempotency keys.
- If the client wants a different outcome they must generate a new `op_id`.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from pydantic import ValidationError
from sqlalchemy import Select, select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.domain.enums import ChangeOp
from kp_api.domain.models import (
    AppliedOp,
    ChangeLog,
    Event,
    User,
    WatchlistItem,
    Workspace,
)
from kp_api.domain.schemas import (
    EventCreate,
    EventUpdate,
    WatchlistItemCreate,
    WatchlistItemSyncMove,
    WatchlistItemSyncUpdate,
)
from kp_api.sync.changelog import record_event_change, record_watchlist_change
from kp_api.sync.schemas import (
    ApplyResponse,
    ChangeEntry,
    ChangesPage,
    OperationRequest,
    OperationResult,
)


class _OperationFailed(Exception):
    def __init__(self, result: OperationResult) -> None:
        self.result = result


def _utcnow() -> datetime:
    return datetime.now(UTC)


async def fetch_changes(
    session: AsyncSession,
    workspace: Workspace,
    since: int,
    limit: int,
) -> ChangesPage:
    rows = (
        await session.scalars(
            select(ChangeLog)
            .where(
                ChangeLog.workspace_id == workspace.id,
                ChangeLog.seq > since,
            )
            .order_by(ChangeLog.seq.asc())
            .limit(limit + 1)
        )
    ).all()

    has_more = len(rows) > limit
    rows = list(rows[:limit])
    next_seq = max((r.seq for r in rows), default=since)
    return ChangesPage(
        changes=[
            ChangeEntry(
                seq=r.seq,
                workspace_id=r.workspace_id,
                entity_type=r.entity_type,
                entity_id=r.entity_id,
                op=ChangeOp(r.op),
                payload=r.payload,
                actor_id=r.actor_id,
                created_at=r.created_at,
            )
            for r in rows
        ],
        next_seq=int(next_seq),
        has_more=has_more,
    )


async def _ensure_event_for_workspace(
    session: AsyncSession, workspace: Workspace, entity_id: UUID
) -> Event:
    event = await session.scalar(
        select(Event).where(Event.id == entity_id, Event.workspace_id == workspace.id)
    )
    if event is None:
        raise _OperationFailed(
            OperationResult(
                op_id=UUID(int=0),  # filled by caller
                status="not_found",
                error="event not found",
            )
        )
    return event


async def _apply_event_create(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    if op.payload is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing payload")
        )
    try:
        body = EventCreate.model_validate(op.payload)
    except ValidationError as exc:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error=str(exc))
        ) from exc

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
    if op.entity_id is not None:
        # Allow the client to suggest the id (helps offline-first dedup); the
        # server still owns the id space so reject anything that collides.
        clash = await session.get(Event, op.entity_id)
        if clash is not None:
            raise _OperationFailed(
                OperationResult(
                    op_id=op.op_id,
                    status="invalid",
                    error="entity_id already exists",
                )
            )
        event.id = op.entity_id
    session.add(event)
    await session.flush()
    seq = await record_event_change(session, event, user.id, ChangeOp.UPSERT)
    return OperationResult(
        op_id=op.op_id,
        status="applied",
        entity_id=event.id,
        version=event.version,
        seq=seq,
    )


async def _apply_event_update(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    if op.entity_id is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing entity_id")
        )
    if op.base_version is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing base_version")
        )
    try:
        event = await _ensure_event_for_workspace(session, workspace, op.entity_id)
    except _OperationFailed as exc:
        exc.result = exc.result.model_copy(update={"op_id": op.op_id})
        raise

    if event.deleted_at is not None:
        raise _OperationFailed(
            OperationResult(
                op_id=op.op_id,
                status="not_found",
                error="event was deleted",
            )
        )
    if event.version != op.base_version:
        raise _OperationFailed(
            OperationResult(
                op_id=op.op_id,
                status="conflict",
                entity_id=event.id,
                current_version=event.version,
            )
        )

    payload: dict[str, Any] = dict(op.payload or {})
    payload.pop("version", None)
    try:
        body = EventUpdate.model_validate({"version": op.base_version, **payload})
    except ValidationError as exc:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error=str(exc))
        ) from exc

    data = body.model_dump(exclude_unset=True, exclude={"version"})
    for key, value in data.items():
        setattr(event, key, value)
    event.version += 1
    await session.flush()
    seq = await record_event_change(session, event, user.id, ChangeOp.UPSERT)
    return OperationResult(
        op_id=op.op_id,
        status="applied",
        entity_id=event.id,
        version=event.version,
        seq=seq,
    )


async def _apply_event_delete(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    if op.entity_id is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing entity_id")
        )
    try:
        event = await _ensure_event_for_workspace(session, workspace, op.entity_id)
    except _OperationFailed as exc:
        exc.result = exc.result.model_copy(update={"op_id": op.op_id})
        raise

    if event.deleted_at is not None:
        # Already gone — idempotent success without writing a new change_log row.
        return OperationResult(
            op_id=op.op_id,
            status="applied",
            entity_id=event.id,
            version=event.version,
        )
    event.deleted_at = _utcnow()
    event.version += 1
    await session.flush()
    seq = await record_event_change(session, event, user.id, ChangeOp.DELETE)
    return OperationResult(
        op_id=op.op_id,
        status="applied",
        entity_id=event.id,
        version=event.version,
        seq=seq,
    )


async def _ensure_watchlist_for_workspace(
    session: AsyncSession, workspace: Workspace, entity_id: UUID
) -> WatchlistItem:
    item = await session.scalar(
        select(WatchlistItem).where(
            WatchlistItem.id == entity_id,
            WatchlistItem.workspace_id == workspace.id,
        )
    )
    if item is None or item.deleted_at is not None:
        raise _OperationFailed(
            OperationResult(
                op_id=UUID(int=0),  # filled by caller
                status="not_found",
                error="watchlist item not found",
            )
        )
    return item


async def _validate_watchlist_parent(
    session: AsyncSession, workspace: Workspace, parent_id: UUID, op_id: UUID
) -> WatchlistItem:
    parent = await session.scalar(
        select(WatchlistItem).where(
            WatchlistItem.id == parent_id,
            WatchlistItem.workspace_id == workspace.id,
            WatchlistItem.deleted_at.is_(None),
        )
    )
    if parent is None:
        raise _OperationFailed(
            OperationResult(op_id=op_id, status="not_found", error="parent not found")
        )
    if parent.parent_id is not None:
        raise _OperationFailed(
            OperationResult(
                op_id=op_id,
                status="invalid",
                error="watchlist nests one level only",
            )
        )
    return parent


# Position math duplicated from `api/v1/watchlist.py` — kept in sync if either
# side changes. The REST path raises HTTPException; this path raises
# _OperationFailed so the surrounding apply machinery records a structured
# OperationResult instead of bubbling a 500 to the client.
async def _compute_watchlist_position(
    session: AsyncSession,
    workspace: Workspace,
    parent_id: UUID | None,
    *,
    op_id: UUID,
    after_id: UUID | None,
    before_id: UUID | None,
    to_end: bool,
    moving_id: UUID | None,
) -> float:
    if after_id is not None and before_id is not None:
        raise _OperationFailed(
            OperationResult(
                op_id=op_id,
                status="invalid",
                error="specify only one of after_id / before_id",
            )
        )

    async def anchor(item_id: UUID) -> WatchlistItem:
        item = await session.scalar(
            select(WatchlistItem).where(
                WatchlistItem.id == item_id,
                WatchlistItem.workspace_id == workspace.id,
                WatchlistItem.deleted_at.is_(None),
            )
        )
        if item is None:
            raise _OperationFailed(
                OperationResult(op_id=op_id, status="not_found", error="anchor not found")
            )
        if item.parent_id != parent_id:
            raise _OperationFailed(
                OperationResult(
                    op_id=op_id,
                    status="invalid",
                    error="anchor belongs to a different parent scope",
                )
            )
        return item

    def scope_filter(stmt: Select[tuple[float]]) -> Select[tuple[float]]:
        stmt = stmt.where(
            WatchlistItem.workspace_id == workspace.id,
            WatchlistItem.deleted_at.is_(None),
        )
        stmt = (
            stmt.where(WatchlistItem.parent_id.is_(None))
            if parent_id is None
            else stmt.where(WatchlistItem.parent_id == parent_id)
        )
        if moving_id is not None:
            stmt = stmt.where(WatchlistItem.id != moving_id)
        return stmt

    if after_id is not None:
        anchor_row = await anchor(after_id)
        next_pos = await session.scalar(
            scope_filter(select(WatchlistItem.position))
            .where(WatchlistItem.position > anchor_row.position)
            .order_by(WatchlistItem.position.asc())
            .limit(1)
        )
        return (
            (anchor_row.position + next_pos) / 2
            if next_pos is not None
            else anchor_row.position + 1.0
        )

    if before_id is not None:
        anchor_row = await anchor(before_id)
        prev_pos = await session.scalar(
            scope_filter(select(WatchlistItem.position))
            .where(WatchlistItem.position < anchor_row.position)
            .order_by(WatchlistItem.position.desc())
            .limit(1)
        )
        return (
            (prev_pos + anchor_row.position) / 2
            if prev_pos is not None
            else anchor_row.position - 1.0
        )

    _ = to_end  # to_end is the implicit default once both anchors are absent
    max_pos = await session.scalar(
        scope_filter(select(WatchlistItem.position))
        .order_by(WatchlistItem.position.desc())
        .limit(1)
    )
    return (max_pos + 1.0) if max_pos is not None else 1.0


async def _apply_watchlist_create(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    if op.payload is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing payload")
        )
    try:
        body = WatchlistItemCreate.model_validate(op.payload)
    except ValidationError as exc:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error=str(exc))
        ) from exc

    if body.parent_id is not None:
        await _validate_watchlist_parent(session, workspace, body.parent_id, op.op_id)

    position = await _compute_watchlist_position(
        session,
        workspace,
        body.parent_id,
        op_id=op.op_id,
        after_id=body.after_id,
        before_id=body.before_id,
        to_end=False,
        moving_id=None,
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
    if op.entity_id is not None:
        clash = await session.get(WatchlistItem, op.entity_id)
        if clash is not None:
            raise _OperationFailed(
                OperationResult(
                    op_id=op.op_id,
                    status="invalid",
                    error="entity_id already exists",
                )
            )
        item.id = op.entity_id
    session.add(item)
    await session.flush()
    seq = await record_watchlist_change(session, item, user.id, ChangeOp.UPSERT)
    return OperationResult(
        op_id=op.op_id,
        status="applied",
        entity_id=item.id,
        version=item.version,
        seq=seq,
    )


async def _apply_watchlist_update(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    if op.entity_id is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing entity_id")
        )
    if op.base_version is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing base_version")
        )
    try:
        item = await _ensure_watchlist_for_workspace(session, workspace, op.entity_id)
    except _OperationFailed as exc:
        exc.result = exc.result.model_copy(update={"op_id": op.op_id})
        raise

    if item.version != op.base_version:
        raise _OperationFailed(
            OperationResult(
                op_id=op.op_id,
                status="conflict",
                entity_id=item.id,
                current_version=item.version,
            )
        )

    try:
        body = WatchlistItemSyncUpdate.model_validate(op.payload or {})
    except ValidationError as exc:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error=str(exc))
        ) from exc

    data = body.model_dump(exclude_unset=True)
    done_change = "done" in data and data["done"] != item.done
    for key in ("title", "kind", "note"):
        if key in data:
            setattr(item, key, data[key])
    if done_change:
        item.done = data["done"]
        if item.done:
            item.done_at = _utcnow()
            item.done_by = user.id
        else:
            item.done_at = None
            item.done_by = None
    item.version += 1
    await session.flush()
    seq = await record_watchlist_change(session, item, user.id, ChangeOp.UPSERT)
    return OperationResult(
        op_id=op.op_id,
        status="applied",
        entity_id=item.id,
        version=item.version,
        seq=seq,
    )


async def _apply_watchlist_move(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    if op.entity_id is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing entity_id")
        )
    if op.base_version is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing base_version")
        )
    try:
        item = await _ensure_watchlist_for_workspace(session, workspace, op.entity_id)
    except _OperationFailed as exc:
        exc.result = exc.result.model_copy(update={"op_id": op.op_id})
        raise

    if item.version != op.base_version:
        raise _OperationFailed(
            OperationResult(
                op_id=op.op_id,
                status="conflict",
                entity_id=item.id,
                current_version=item.version,
            )
        )

    try:
        body = WatchlistItemSyncMove.model_validate(op.payload or {})
    except ValidationError as exc:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error=str(exc))
        ) from exc

    new_parent_id = body.parent_id if body.set_parent else item.parent_id
    if new_parent_id is not None:
        if new_parent_id == item.id:
            raise _OperationFailed(
                OperationResult(
                    op_id=op.op_id,
                    status="invalid",
                    error="cannot make an item its own parent",
                )
            )
        await _validate_watchlist_parent(session, workspace, new_parent_id, op.op_id)
        has_children = await session.scalar(
            select(WatchlistItem.id)
            .where(
                WatchlistItem.parent_id == item.id,
                WatchlistItem.deleted_at.is_(None),
            )
            .limit(1)
        )
        if has_children is not None:
            raise _OperationFailed(
                OperationResult(
                    op_id=op.op_id,
                    status="invalid",
                    error="cannot move a parent item under another parent",
                )
            )

    new_position = await _compute_watchlist_position(
        session,
        workspace,
        new_parent_id,
        op_id=op.op_id,
        after_id=body.after_id,
        before_id=body.before_id,
        to_end=body.to_end,
        moving_id=item.id,
    )

    item.parent_id = new_parent_id
    item.position = new_position
    item.version += 1
    await session.flush()
    seq = await record_watchlist_change(session, item, user.id, ChangeOp.UPSERT)
    return OperationResult(
        op_id=op.op_id,
        status="applied",
        entity_id=item.id,
        version=item.version,
        seq=seq,
    )


async def _apply_watchlist_delete(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    if op.entity_id is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="invalid", error="missing entity_id")
        )
    item = await session.scalar(
        select(WatchlistItem).where(
            WatchlistItem.id == op.entity_id,
            WatchlistItem.workspace_id == workspace.id,
        )
    )
    if item is None:
        raise _OperationFailed(
            OperationResult(op_id=op.op_id, status="not_found", error="watchlist item not found")
        )
    if item.deleted_at is not None:
        # Idempotent — already gone.
        return OperationResult(
            op_id=op.op_id,
            status="applied",
            entity_id=item.id,
            version=item.version,
        )

    now = _utcnow()
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
    seq = await record_watchlist_change(session, item, user.id, ChangeOp.DELETE)
    return OperationResult(
        op_id=op.op_id,
        status="applied",
        entity_id=item.id,
        version=item.version,
        seq=seq,
    )


_APPLIERS = {
    ("event", "create"): _apply_event_create,
    ("event", "update"): _apply_event_update,
    ("event", "delete"): _apply_event_delete,
    ("watchlist_item", "create"): _apply_watchlist_create,
    ("watchlist_item", "update"): _apply_watchlist_update,
    ("watchlist_item", "delete"): _apply_watchlist_delete,
    ("watchlist_item", "move"): _apply_watchlist_move,
}


async def _apply_one(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    op: OperationRequest,
) -> OperationResult:
    cached = await session.get(AppliedOp, op.op_id)
    if cached is not None:
        if cached.workspace_id != workspace.id:
            return OperationResult(
                op_id=op.op_id,
                status="forbidden",
                error="op_id belongs to another workspace",
            )
        return OperationResult.model_validate(cached.response)

    applier = _APPLIERS.get((op.entity, op.op))
    if applier is None:
        result = OperationResult(op_id=op.op_id, status="invalid", error="unsupported operation")
    else:
        try:
            async with session.begin_nested():
                result = await applier(session, user, workspace, op)
        except _OperationFailed as exc:
            result = exc.result

    session.add(
        AppliedOp(
            op_id=op.op_id,
            actor_id=user.id,
            workspace_id=workspace.id,
            response=result.model_dump(mode="json"),
        )
    )
    await session.flush()
    return result


async def apply_operations(
    session: AsyncSession,
    user: User,
    workspace: Workspace,
    operations: list[OperationRequest],
) -> ApplyResponse:
    results = [await _apply_one(session, user, workspace, op) for op in operations]
    return ApplyResponse(results=results)
