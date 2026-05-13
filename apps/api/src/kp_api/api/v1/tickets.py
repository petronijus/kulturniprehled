"""Tickets endpoints: presigned upload/download URLs and ticket registration.

Flow:
1. Client calls `POST /v1/tickets/upload-url` with the event id and a mime
   type. The server returns an `object_key` plus a short-lived presigned
   PUT URL that the client uses to stream the bytes straight to MinIO. No
   bytes ever touch the API process.
2. After the upload finishes the client posts `POST /v1/tickets` with the
   `object_key` and metadata. The server verifies the object exists in
   MinIO (defence against a forged success report), records the ticket
   row, and emits a `change_log` upsert so other devices learn about it
   on their next sync.
3. To download a ticket later the client calls `GET /v1/tickets/{id}/url`
   and gets a fresh presigned GET URL.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.storage import minio as storage
from kp_api.api.deps import CurrentUser, SessionDep
from kp_api.domain.enums import ChangeOp
from kp_api.domain.models import Event, Ticket, User, Workspace, WorkspaceMember
from kp_api.domain.schemas import (
    TicketCreate,
    TicketDownloadUrlResponse,
    TicketListResponse,
    TicketResponse,
    TicketUploadUrlRequest,
    TicketUploadUrlResponse,
)
from kp_api.sync.changelog import record_ticket_change

router = APIRouter(prefix="/v1/tickets", tags=["tickets"])
events_router = APIRouter(prefix="/v1/events", tags=["tickets"])


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


async def _ticket_in_workspace(
    session: AsyncSession, workspace: Workspace, ticket_id: UUID
) -> Ticket:
    ticket = await session.scalar(
        select(Ticket).where(
            Ticket.id == ticket_id,
            Ticket.workspace_id == workspace.id,
            Ticket.deleted_at.is_(None),
        )
    )
    if ticket is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "ticket not found")
    return ticket


@router.post(
    "/upload-url",
    response_model=TicketUploadUrlResponse,
    status_code=status.HTTP_201_CREATED,
)
async def upload_url(
    body: TicketUploadUrlRequest,
    session: SessionDep,
    user: CurrentUser,
) -> TicketUploadUrlResponse:
    workspace = await _user_workspace(session, user)
    await _event_in_workspace(session, workspace, body.event_id)
    presigned = storage.make_upload_url(body.event_id, body.mime_type)
    return TicketUploadUrlResponse(
        object_key=presigned.object_key,
        upload_url=presigned.url,
        expires_in_seconds=presigned.expires_in_seconds,
    )


@router.post("", response_model=TicketResponse, status_code=status.HTTP_201_CREATED)
async def register_ticket(
    body: TicketCreate,
    session: SessionDep,
    user: CurrentUser,
) -> TicketResponse:
    workspace = await _user_workspace(session, user)
    event = await _event_in_workspace(session, workspace, body.event_id)

    if not storage.object_exists(body.object_key):
        # The client claimed they finished uploading but the object isn't
        # there — refuse to record a ticket pointing at a phantom blob.
        raise HTTPException(422, "object not found in storage")

    ticket = Ticket(
        event_id=event.id,
        workspace_id=workspace.id,
        object_key=body.object_key,
        mime_type=body.mime_type,
        original_filename=body.original_filename,
        size_bytes=body.size_bytes,
        hash_sha256=body.hash_sha256,
        uploaded_by=user.id,
        version=1,
    )
    session.add(ticket)
    await session.flush()
    await record_ticket_change(session, ticket, user.id, ChangeOp.UPSERT)
    await session.commit()
    await session.refresh(ticket)
    return TicketResponse.model_validate(ticket)


@router.get("/{ticket_id}/url", response_model=TicketDownloadUrlResponse)
async def get_download_url(
    ticket_id: UUID,
    session: SessionDep,
    user: CurrentUser,
) -> TicketDownloadUrlResponse:
    workspace = await _user_workspace(session, user)
    ticket = await _ticket_in_workspace(session, workspace, ticket_id)
    presigned = storage.make_download_url(ticket.object_key)
    return TicketDownloadUrlResponse(
        download_url=presigned.url,
        expires_in_seconds=presigned.expires_in_seconds,
    )


@router.delete("/{ticket_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_ticket(
    ticket_id: UUID,
    session: SessionDep,
    user: CurrentUser,
) -> Response:
    workspace = await _user_workspace(session, user)
    ticket = await _ticket_in_workspace(session, workspace, ticket_id)
    ticket.deleted_at = _utcnow()
    ticket.version += 1
    await session.flush()
    await record_ticket_change(session, ticket, user.id, ChangeOp.DELETE)
    await session.commit()
    # The blob stays in MinIO until a sweeper job runs — that gives us a
    # window to recover from accidental deletes and avoids racing with
    # in-flight downloads.
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@events_router.get(
    "/{event_id}/tickets",
    response_model=TicketListResponse,
)
async def list_event_tickets(
    event_id: UUID,
    session: SessionDep,
    user: CurrentUser,
    include_deleted: Annotated[bool, "query"] = False,
) -> TicketListResponse:
    workspace = await _user_workspace(session, user)
    await _event_in_workspace(session, workspace, event_id)
    stmt = select(Ticket).where(
        Ticket.event_id == event_id, Ticket.workspace_id == workspace.id
    )
    if not include_deleted:
        stmt = stmt.where(Ticket.deleted_at.is_(None))
    stmt = stmt.order_by(Ticket.created_at.asc())
    rows = (await session.scalars(stmt)).all()
    return TicketListResponse(items=[TicketResponse.model_validate(t) for t in rows])
