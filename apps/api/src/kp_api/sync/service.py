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

from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.domain.enums import ChangeOp
from kp_api.domain.models import AppliedOp, ChangeLog, Event, User, Workspace
from kp_api.domain.schemas import EventCreate, EventUpdate
from kp_api.sync.changelog import record_event_change
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
    return datetime.now(timezone.utc)


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
        select(Event).where(
            Event.id == entity_id, Event.workspace_id == workspace.id
        )
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


_APPLIERS = {
    ("event", "create"): _apply_event_create,
    ("event", "update"): _apply_event_update,
    ("event", "delete"): _apply_event_delete,
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
        result = OperationResult(
            op_id=op.op_id, status="invalid", error="unsupported operation"
        )
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
