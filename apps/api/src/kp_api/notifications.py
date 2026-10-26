"""Decide when an event is worth a notification on every member's phone.

Three things produce one: an event is created, its venue or programme
changes, or a member asks for it (`POST /v1/events/{id}/notifications`, or a
`notification` create through the outbox). The phones show what arrives in
`/v1/sync` once `deliver_after` has passed; the author's own phone included.

Automatic notifications wait `COALESCE_WINDOW` before they are due. Any
further reason for the same event inside that window merges into the pending
row (one more `change_log` entry for it) rather than adding a second
notification. A manual notification with nothing pending is due at once.

Times come from the database clock, read after the event row is locked, and
a merge needs `MERGE_MARGIN` to spare before the deadline. Otherwise a merge
decided just before `deliver_after` could commit after a phone had already
pulled a page whose `server_time` passed it — and shown the earlier version,
which it never shows again.
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

from sqlalchemy import DateTime, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.domain.enums import ChangeOp, NotificationChange, NotificationKind
from kp_api.domain.models import Event, EventNotification
from kp_api.sync.changelog import record_notification_change

COALESCE_WINDOW = timedelta(minutes=2)
MERGE_MARGIN = timedelta(seconds=15)


class EventGone(Exception):
    """The event was deleted before the notification could be recorded."""


# Event attribute → the change it announces. Only these fields notify;
# a new cover, a typo in the title or a moved departure time stay silent.
WATCHED_FIELDS: dict[str, NotificationChange] = {
    "venue_address": NotificationChange.VENUE,
    "notes": NotificationChange.PROGRAM,
}

_KIND_RANK = {
    NotificationKind.EVENT_CHANGED: 0,
    NotificationKind.MANUAL: 1,
    NotificationKind.EVENT_CREATED: 2,
}


async def db_clock(session: AsyncSession) -> datetime:
    """The database's wall clock now (not the transaction start)."""

    value: datetime | None = await session.scalar(
        select(func.clock_timestamp(type_=DateTime(timezone=True)))
    )
    assert value is not None
    return value.astimezone(UTC)


def _normalized(value: Any) -> Any:
    # Whitespace-only edits and "" vs null are not news.
    if isinstance(value, str):
        return value.strip() or None
    return value


def watched_snapshot(event: Event) -> dict[str, Any]:
    """The watched fields of `event`, taken before a mutation."""

    return {field: _normalized(getattr(event, field)) for field in WATCHED_FIELDS}


def changes_since(before: dict[str, Any], event: Event) -> list[NotificationChange]:
    """The watched fields of `event` that differ from the `before` snapshot."""

    return sorted(
        {
            change
            for field, change in WATCHED_FIELDS.items()
            if before[field] != _normalized(getattr(event, field))
        }
    )


def stronger_kind(a: NotificationKind, b: NotificationKind) -> NotificationKind:
    return a if _KIND_RANK[a] >= _KIND_RANK[b] else b


async def announce(
    session: AsyncSession,
    event: Event,
    actor_id: UUID,
    kind: NotificationKind,
    changes: Iterable[NotificationChange] = (),
    message: str | None = None,
    now: datetime | None = None,
) -> EventNotification:
    """Create a notification for `event`, or merge into its pending one.

    Locks the event row first, so two requests announcing the same event
    serialize and the second one finds the first one's pending row; raises
    `EventGone` if the event was deleted meanwhile. `now` is for tests."""

    deleted_at = await session.scalar(
        select(Event.deleted_at).where(Event.id == event.id).with_for_update()
    )
    if deleted_at is not None:
        raise EventGone(event.id)
    now = now or await db_clock(session)
    message = _normalized(message)
    pending = await session.scalar(
        select(EventNotification)
        .where(
            EventNotification.event_id == event.id,
            EventNotification.deleted_at.is_(None),
            EventNotification.deliver_after > now + MERGE_MARGIN,
        )
        .order_by(EventNotification.deliver_after.desc())
        .limit(1)
    )
    if pending is not None:
        pending.kind = stronger_kind(NotificationKind(pending.kind), kind)
        pending.changes = sorted({*pending.changes, *changes})
        if message is not None:
            pending.message = message
        pending.version += 1
        await session.flush()
        await record_notification_change(session, pending, actor_id, ChangeOp.UPSERT)
        return pending

    notification = EventNotification(
        workspace_id=event.workspace_id,
        event_id=event.id,
        kind=kind,
        changes=sorted(set(changes)),
        message=message,
        created_by=actor_id,
        deliver_after=now if kind is NotificationKind.MANUAL else now + COALESCE_WINDOW,
        version=1,
    )
    session.add(notification)
    await session.flush()
    await record_notification_change(session, notification, actor_id, ChangeOp.UPSERT)
    return notification


async def withdraw_pending(
    session: AsyncSession, event: Event, actor_id: UUID, now: datetime | None = None
) -> None:
    """Soft-delete the pending notifications of a deleted event."""

    now = now or await db_clock(session)
    rows = (
        await session.scalars(
            select(EventNotification).where(
                EventNotification.event_id == event.id,
                EventNotification.deleted_at.is_(None),
                EventNotification.deliver_after > now,
            )
        )
    ).all()
    for row in rows:
        row.deleted_at = now
        row.version += 1
        await session.flush()
        await record_notification_change(session, row, actor_id, ChangeOp.DELETE)
