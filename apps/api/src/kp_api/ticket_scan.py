"""Fill `tickets.codes` from the ticket blob and tell the phones.

Runs after `POST /v1/tickets` as a background task (so registering a ticket
does not wait for a PDF render), from a sweep the API starts with itself and
repeats hourly, and from `python -m kp_api.cli scan-ticket-codes`. A ticket
whose `codes` is still NULL has not been scanned yet: the sweep picks up
what a restart interrupted, what a failed scan left behind, and — on the
first start after migration 0020 — every ticket uploaded before it.
"""

from __future__ import annotations

import asyncio
from uuid import UUID

import structlog
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.db import get_sessionmaker
from kp_api.adapters.storage import minio as storage
from kp_api.domain.enums import ChangeOp
from kp_api.domain.models import Ticket
from kp_api.domain.ticket_codes import (
    UnreadableTicket,
    UnsupportedTicketType,
    decode_ticket_codes,
)
from kp_api.sync.changelog import record_ticket_change

logger = structlog.get_logger("kp_api.ticket_scan")

SWEEP_INTERVAL_SECONDS = 3600.0


def _decode_blob(ticket_id: UUID, object_key: str, mime_type: str) -> list[dict[str, object]]:
    data = storage.read_object(object_key)
    try:
        return [code.to_payload() for code in decode_ticket_codes(data, mime_type)]
    except UnsupportedTicketType:
        # An ICS or other non-visual ticket carries no code; record that it
        # was looked at so it is not rescanned forever.
        return []
    except UnreadableTicket as exc:
        # A corrupt file stays corrupt: say so once and record "no codes"
        # rather than failing it again every hour. Storage and database
        # errors are not caught here, so those stay NULL and are retried.
        logger.warning(
            "ticket_unreadable", ticket_id=str(ticket_id), mime_type=mime_type, error=str(exc)
        )
        return []


async def _decode(ticket_id: UUID, object_key: str, mime_type: str) -> list[dict[str, object]]:
    return await asyncio.to_thread(_decode_blob, ticket_id, object_key, mime_type)


async def _store_codes(
    session: AsyncSession, ticket_id: UUID, codes: list[dict[str, object]]
) -> None:
    locked = await session.scalar(
        select(Ticket)
        .where(Ticket.id == ticket_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if locked is None or locked.deleted_at is not None:
        # Deleted while it was being decoded: an UPSERT now would resurrect
        # it on the phones.
        await session.rollback()
        return
    if locked.codes == codes:
        await session.rollback()
        return
    locked.codes = codes
    locked.version += 1
    await session.flush()
    await record_ticket_change(session, locked, locked.uploaded_by, ChangeOp.UPSERT)
    await session.commit()
    logger.info("ticket_scanned", ticket_id=str(ticket_id), codes=len(codes))


async def scan_ticket(session: AsyncSession, ticket_id: UUID, *, rescan: bool = False) -> bool:
    """Decode one ticket and store its codes. Returns False when the scan
    failed; the error is logged with the ticket id and `codes` stays NULL,
    so the next sweep retries it."""

    try:
        ticket = await session.get(Ticket, ticket_id)
        if ticket is None or ticket.deleted_at is not None:
            return True
        if ticket.codes is not None and not rescan:
            return True
        object_key, mime_type = ticket.object_key, ticket.mime_type
        # Release the row while the blob is rendered; the write re-reads it.
        await session.rollback()
        codes = await _decode(ticket_id, object_key, mime_type)
        await _store_codes(session, ticket_id, codes)
        return True
    except Exception:
        await session.rollback()
        logger.exception("ticket_scan_failed", ticket_id=str(ticket_id))
        return False


async def scan_ticket_in_background(ticket_id: UUID) -> None:
    factory = get_sessionmaker()
    async with factory() as session:
        await scan_ticket(session, ticket_id)


async def scan_pending_tickets(*, rescan: bool = False) -> tuple[int, int]:
    """Scan every live ticket still lacking codes (all of them with
    `rescan`). One ticket's failure does not stop the others. Returns
    (scanned, failed)."""

    factory = get_sessionmaker()
    async with factory() as session:
        stmt = select(Ticket.id).where(Ticket.deleted_at.is_(None))
        if not rescan:
            stmt = stmt.where(Ticket.codes.is_(None))
        ids = list((await session.scalars(stmt.order_by(Ticket.created_at))).all())
        await session.rollback()
        failed = 0
        for ticket_id in ids:
            if not await scan_ticket(session, ticket_id, rescan=rescan):
                failed += 1
        return len(ids) - failed, failed


async def sweep_forever(interval_seconds: float = SWEEP_INTERVAL_SECONDS) -> None:
    """The API's own retry loop; cancelled on shutdown."""

    while True:
        try:
            scanned, failed = await scan_pending_tickets()
            if failed:
                logger.error("ticket_sweep_failures", scanned=scanned, failed=failed)
            elif scanned:
                logger.info("ticket_sweep", scanned=scanned)
        except Exception:
            logger.exception("ticket_sweep_crashed")
        await asyncio.sleep(interval_seconds)
