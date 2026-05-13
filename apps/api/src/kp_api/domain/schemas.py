"""Pydantic models used as the API contract.

Domain ORM models live in `kp_api.domain.models`; these are the shapes the
HTTP layer accepts and returns. Keeping them separate means the SQL schema
can change without breaking external clients.
"""

from __future__ import annotations

from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from kp_api.domain.enums import (
    CostKind,
    CostSplit,
    EventCategory,
    EventSource,
    EventStatus,
)


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


class TicketUploadUrlRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    event_id: UUID
    mime_type: str = Field(min_length=1, max_length=120)
    original_filename: str | None = Field(default=None, max_length=255)
    size_bytes: int | None = Field(default=None, ge=0)


class TicketUploadUrlResponse(BaseModel):
    object_key: str
    upload_url: str
    expires_in_seconds: int


class TicketCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    event_id: UUID
    object_key: str = Field(min_length=1, max_length=512)
    mime_type: str = Field(min_length=1, max_length=120)
    original_filename: str | None = Field(default=None, max_length=255)
    size_bytes: int | None = Field(default=None, ge=0)
    hash_sha256: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")


class TicketResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    event_id: UUID
    workspace_id: UUID
    mime_type: str
    original_filename: str | None
    size_bytes: int | None
    hash_sha256: str | None
    uploaded_by: UUID
    version: int
    created_at: datetime
    updated_at: datetime


class TicketListResponse(BaseModel):
    items: list[TicketResponse]


class TicketDownloadUrlResponse(BaseModel):
    download_url: str
    expires_in_seconds: int


_CURRENCY_PATTERN = r"^[A-Za-z]{3}$"


class CostCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    amount_cents: int = Field(ge=0)
    currency: str = Field(min_length=3, max_length=3, pattern=_CURRENCY_PATTERN)
    kind: CostKind = CostKind.TICKET
    split: CostSplit = CostSplit.SHARED
    note: str | None = None
    paid_at: date
    paid_by: UUID | None = None  # defaults to current user server-side


class CostUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1)
    amount_cents: int | None = Field(default=None, ge=0)
    currency: str | None = Field(
        default=None, min_length=3, max_length=3, pattern=_CURRENCY_PATTERN
    )
    kind: CostKind | None = None
    split: CostSplit | None = None
    note: str | None = None
    paid_at: date | None = None


class CostResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    event_id: UUID
    workspace_id: UUID
    amount_cents: int
    currency: str
    kind: CostKind
    paid_by: UUID
    split: CostSplit
    note: str | None
    paid_at: date
    version: int
    created_at: datetime
    updated_at: datetime


class CostListResponse(BaseModel):
    items: list[CostResponse]
    total_in_primary_currency: int
    primary_currency: str = "CZK"


class StatsByMonth(BaseModel):
    month: int
    events: int
    total_cost_cents: int


class StatsByCategory(BaseModel):
    category: EventCategory
    count: int


class StatsTopVenue(BaseModel):
    name: str
    count: int


class StatsResponse(BaseModel):
    year: int
    total_events: int
    attended: int
    upcoming: int
    by_category: list[StatsByCategory]
    by_month: list[StatsByMonth]
    top_venues: list[StatsTopVenue]
    total_cost_cents: int
    primary_currency: str = "CZK"
