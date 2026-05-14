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
    WatchlistKind,
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


class CostCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    amount_cents: int = Field(ge=0)
    kind: CostKind = CostKind.TICKET
    split: CostSplit = CostSplit.SHARED
    note: str | None = None
    paid_at: date
    paid_by: UUID | None = None  # defaults to current user server-side


class CostUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1)
    amount_cents: int | None = Field(default=None, ge=0)
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
    total_amount_cents: int


class WatchlistItemCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=255)
    kind: WatchlistKind
    parent_id: UUID | None = None
    note: str | None = None
    # Optional anchor positions; if both are None the server appends.
    after_id: UUID | None = None
    before_id: UUID | None = None


class WatchlistItemUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1, description="Last seen version; server rejects on mismatch.")
    title: str | None = Field(default=None, min_length=1, max_length=255)
    kind: WatchlistKind | None = None
    note: str | None = None


class WatchlistCheckRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1)
    done: bool


class WatchlistMoveRequest(BaseModel):
    """Reorder within a parent or move into a different parent.

    Exactly one of the three positioning fields should be set:
    `before_id`, `after_id`, or `to_end=true`. `parent_id` is honoured
    when present (use `None` to move to the root); when omitted the
    item's current parent is kept.
    """

    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1)
    parent_id: UUID | None = None
    set_parent: bool = Field(
        default=False,
        description=(
            "Set to true to apply parent_id verbatim (including None for root). "
            "When false, the item's current parent is kept."
        ),
    )
    before_id: UUID | None = None
    after_id: UUID | None = None
    to_end: bool = False


class WatchlistItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    workspace_id: UUID
    parent_id: UUID | None
    title: str
    kind: WatchlistKind
    note: str | None
    position: float
    done: bool
    done_at: datetime | None
    done_by: UUID | None
    created_by: UUID
    version: int
    created_at: datetime
    updated_at: datetime


class WatchlistListResponse(BaseModel):
    items: list[WatchlistItemResponse]


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
