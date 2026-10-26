"""Pydantic models for the sync API."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from kp_api.domain.enums import ChangeOp

OperationStatus = Literal["applied", "conflict", "not_found", "invalid", "forbidden"]


class ChangeEntry(BaseModel):
    seq: int
    workspace_id: UUID
    entity_type: str
    entity_id: UUID
    op: ChangeOp
    payload: dict[str, Any]
    actor_id: UUID | None
    created_at: datetime


class ChangesPage(BaseModel):
    changes: list[ChangeEntry]
    next_seq: int
    has_more: bool
    # Clients compare notification `deliver_after` against this, not their
    # own clock, so a phone running fast cannot show a notification that is
    # still collecting merges.
    server_time: datetime


class OperationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    op_id: UUID
    # Any string: an entity this server does not know fails as one
    # `invalid` result (see `_APPLIERS`), not as a 422 for the whole batch —
    # a newer app talking to an older API must not wedge its outbox.
    entity: str = Field(min_length=1, max_length=40)
    op: str = Field(min_length=1, max_length=20)  # unknown → `invalid`, as `entity`
    entity_id: UUID | None = None
    base_version: int | None = Field(default=None, ge=1)
    payload: dict[str, Any] | None = None


class ApplyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operations: list[OperationRequest] = Field(min_length=1, max_length=200)


class OperationResult(BaseModel):
    op_id: UUID
    status: OperationStatus
    entity_id: UUID | None = None
    version: int | None = None
    seq: int | None = None
    current_version: int | None = None
    error: str | None = None


class ApplyResponse(BaseModel):
    results: list[OperationResult]
