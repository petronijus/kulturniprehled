"""Pydantic models for the sync API."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from kp_api.domain.enums import ChangeOp

OperationKind = Literal["create", "update", "delete", "move"]
EntityKind = Literal["event", "watchlist_item"]
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


class OperationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    op_id: UUID
    entity: EntityKind
    op: OperationKind
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
