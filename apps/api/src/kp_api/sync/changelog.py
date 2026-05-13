"""Append entries to `change_log` for every mutation that must reach mobile clients.

This module is the only place that knows how to serialize a domain row into
the sync payload. Endpoints call `record_event_change(...)` after they have
mutated an `Event` and before they commit; the helper inserts the row into
`change_log` and returns the assigned `seq` so the caller can report it back
to the client.

Why explicit calls instead of SQLAlchemy `after_update` listeners?
- Knowing the current actor is essential for the audit trail and would
  otherwise have to be smuggled into `Session.info`, which is error prone.
- Soft delete is a regular UPDATE — distinguishing it from an edit inside a
  generic listener is fragile.
- Tests are easier to reason about when the write is visible in the handler.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import insert
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.domain.enums import ChangeOp
from kp_api.domain.models import ChangeLog, Cost, Event, Ticket


def _isoformat(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


def serialize_event(event: Event) -> dict[str, Any]:
    """Stable JSON shape of an `Event` row for mobile clients.

    Keep this stable across releases — clients store the payload verbatim in
    their local cache and replay it on conflict resolution. Adding fields is
    safe; removing or renaming is a breaking change."""

    return {
        "id": str(event.id),
        "workspace_id": str(event.workspace_id),
        "title": event.title,
        "category": event.category,
        "venue_id": str(event.venue_id) if event.venue_id else None,
        "starts_at": _isoformat(event.starts_at),
        "ends_at": _isoformat(event.ends_at),
        "venue_timezone": event.venue_timezone,
        "status": event.status,
        "source": event.source,
        "notes": event.notes,
        "created_by": str(event.created_by),
        "version": event.version,
        "created_at": _isoformat(event.created_at),
        "updated_at": _isoformat(event.updated_at),
        "deleted_at": _isoformat(event.deleted_at),
    }


async def record_event_change(
    session: AsyncSession,
    event: Event,
    actor_id: UUID,
    op: ChangeOp,
) -> int:
    """Insert a `change_log` row for `event` and return the assigned `seq`."""

    result = await session.execute(
        insert(ChangeLog)
        .values(
            workspace_id=event.workspace_id,
            entity_type="event",
            entity_id=event.id,
            op=op,
            payload=serialize_event(event),
            actor_id=actor_id,
        )
        .returning(ChangeLog.seq)
    )
    seq = result.scalar_one()
    return int(seq)


def serialize_ticket(ticket: Ticket) -> dict[str, Any]:
    """Public ticket payload for sync.

    `object_key` is deliberately omitted — mobile clients fetch the blob via
    `GET /v1/tickets/{id}/url`. Exposing the MinIO path is not a security
    problem (the secret is the signature), but it ties the public payload to
    an internal storage layout we may change."""

    return {
        "id": str(ticket.id),
        "event_id": str(ticket.event_id),
        "workspace_id": str(ticket.workspace_id),
        "mime_type": ticket.mime_type,
        "original_filename": ticket.original_filename,
        "size_bytes": ticket.size_bytes,
        "hash_sha256": ticket.hash_sha256,
        "uploaded_by": str(ticket.uploaded_by),
        "version": ticket.version,
        "created_at": _isoformat(ticket.created_at),
        "updated_at": _isoformat(ticket.updated_at),
        "deleted_at": _isoformat(ticket.deleted_at),
    }


async def record_ticket_change(
    session: AsyncSession,
    ticket: Ticket,
    actor_id: UUID,
    op: ChangeOp,
) -> int:
    result = await session.execute(
        insert(ChangeLog)
        .values(
            workspace_id=ticket.workspace_id,
            entity_type="ticket",
            entity_id=ticket.id,
            op=op,
            payload=serialize_ticket(ticket),
            actor_id=actor_id,
        )
        .returning(ChangeLog.seq)
    )
    seq = result.scalar_one()
    return int(seq)


def serialize_cost(cost: Cost) -> dict[str, Any]:
    return {
        "id": str(cost.id),
        "event_id": str(cost.event_id),
        "workspace_id": str(cost.workspace_id),
        "amount_cents": cost.amount_cents,
        "currency": cost.currency,
        "kind": cost.kind,
        "paid_by": str(cost.paid_by),
        "split": cost.split,
        "note": cost.note,
        "paid_at": cost.paid_at.isoformat(),
        "version": cost.version,
        "created_at": _isoformat(cost.created_at),
        "updated_at": _isoformat(cost.updated_at),
        "deleted_at": _isoformat(cost.deleted_at),
    }


async def record_cost_change(
    session: AsyncSession,
    cost: Cost,
    actor_id: UUID,
    op: ChangeOp,
) -> int:
    result = await session.execute(
        insert(ChangeLog)
        .values(
            workspace_id=cost.workspace_id,
            entity_type="cost",
            entity_id=cost.id,
            op=op,
            payload=serialize_cost(cost),
            actor_id=actor_id,
        )
        .returning(ChangeLog.seq)
    )
    seq = result.scalar_one()
    return int(seq)
