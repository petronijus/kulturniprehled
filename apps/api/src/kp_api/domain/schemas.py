"""Pydantic models used as the API contract.

Domain ORM models live in `kp_api.domain.models`; these are the shapes the
HTTP layer accepts and returns. Keeping them separate means the SQL schema
can change without breaking external clients.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from kp_api.domain.enums import EventCategory, EventSource, EventStatus


class EventCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=255)
    category: EventCategory
    venue_id: UUID | None = None
    starts_at: datetime
    ends_at: datetime | None = None
    venue_timezone: str | None = Field(default=None, max_length=60)
    status: EventStatus = EventStatus.PLANNED
    source: EventSource = EventSource.MANUAL
    notes: str | None = None


class EventUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1, description="Last seen version; server rejects on mismatch.")
    title: str | None = Field(default=None, min_length=1, max_length=255)
    category: EventCategory | None = None
    venue_id: UUID | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    venue_timezone: str | None = Field(default=None, max_length=60)
    status: EventStatus | None = None
    notes: str | None = None


class EventResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    workspace_id: UUID
    title: str
    category: EventCategory
    venue_id: UUID | None
    starts_at: datetime
    ends_at: datetime | None
    venue_timezone: str | None
    status: EventStatus
    source: EventSource
    notes: str | None
    created_by: UUID
    version: int
    created_at: datetime
    updated_at: datetime


class EventListResponse(BaseModel):
    items: list[EventResponse]
    total: int
