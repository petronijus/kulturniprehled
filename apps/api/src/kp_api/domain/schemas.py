"""Pydantic models used as the API contract.

Domain ORM models live in `kp_api.domain.models`; these are the shapes the
HTTP layer accepts and returns. Keeping them separate means the SQL schema
can change without breaking external clients.
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from kp_api.domain.enums import (
    CostKind,
    CostSplit,
    EventCategory,
    EventSource,
    EventStatus,
    PlanStatus,
    SeasonLane,
    SeasonStatus,
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
    cover_image_url: str | None = Field(default=None, max_length=1024)
    venue_image_url: str | None = Field(default=None, max_length=1024)
    venue_address: str | None = None
    departure_at: datetime | None = None
    spotify_playlist_url: str | None = Field(default=None, max_length=1024)


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
    cover_image_url: str | None = Field(default=None, max_length=1024)
    venue_image_url: str | None = Field(default=None, max_length=1024)
    venue_address: str | None = None
    departure_at: datetime | None = None
    spotify_playlist_url: str | None = Field(default=None, max_length=1024)


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
    cover_image_url: str | None
    venue_image_url: str | None
    venue_address: str | None
    departure_at: datetime | None
    spotify_playlist_url: str | None
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


class WatchlistItemSyncUpdate(BaseModel):
    """Payload for the `("watchlist_item", "update")` outbox op.

    Differs from `WatchlistItemUpdate` (REST PATCH body) in two ways: it
    omits `version` because the sync envelope carries `base_version`, and
    it includes `done` so a single outbox op can also toggle the checkbox
    instead of needing a separate `/check` round-trip.
    """

    model_config = ConfigDict(extra="forbid")

    title: str | None = Field(default=None, min_length=1, max_length=255)
    kind: WatchlistKind | None = None
    note: str | None = None
    done: bool | None = None


class WatchlistItemSyncMove(BaseModel):
    """Payload for the `("watchlist_item", "move")` outbox op."""

    model_config = ConfigDict(extra="forbid")

    parent_id: UUID | None = None
    set_parent: bool = False
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


class SeasonCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str = Field(min_length=1, max_length=20)
    starts_on: date
    ends_on: date
    archive_current: bool = False


class SeasonResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    workspace_id: UUID
    label: str
    starts_on: date
    ends_on: date
    status: SeasonStatus
    novelty_ack_at: datetime | None
    version: int
    created_at: datetime
    updated_at: datetime


class SeasonListResponse(BaseModel):
    items: list[SeasonResponse]
    total: int


class CandidateUpsert(BaseModel):
    model_config = ConfigDict(extra="forbid")

    dedup_key: str = Field(pattern=r"^[0-9a-f]{16,64}$")
    lane: SeasonLane
    title: str = Field(min_length=1, max_length=255)
    starts_at: datetime
    ends_at: datetime | None = None
    venue: str | None = Field(default=None, max_length=255)
    url: str | None = Field(default=None, max_length=1024)
    price_czk: str | None = Field(default=None, max_length=40)
    program: list[dict[str, object]] | None = None
    detail: dict[str, object] | None = None
    enriched_at: datetime | None = None
    score: float | None = Field(default=None, ge=0.0, le=1.0)
    why_cs: str | None = None
    source_type: str | None = Field(default=None, max_length=20)
    source_name: str | None = Field(default=None, max_length=120)
    season_event: bool = False
    tickets_available: bool | None = None


class SeasonPoolPutRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    items: list[CandidateUpsert] = Field(max_length=1000)


class SeasonPoolPutResult(BaseModel):
    created: int
    updated: int
    unchanged: int
    # Items that reached the pool — the payload minus the vetoed ones.
    total: int
    # Refused on arrival because their venue is vetoed.
    vetoed: int = 0
    # Already-stored candidates at a vetoed venue, soft-deleted by this run.
    purged: int = 0


class CandidateResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    season_id: UUID
    workspace_id: UUID
    dedup_key: str
    lane: SeasonLane
    title: str
    starts_at: datetime
    ends_at: datetime | None
    venue: str | None
    url: str | None
    price_czk: str | None
    program: list[dict[str, object]] | None
    detail: dict[str, object] | None
    enriched_at: datetime | None
    score: float | None
    why_cs: str | None
    source_type: str | None
    source_name: str | None
    season_event: bool
    tickets_available: bool | None
    plan_status: PlanStatus
    plan_status_at: datetime | None
    note: str | None
    first_seen_at: datetime
    last_seen_at: datetime
    version: int
    created_at: datetime
    updated_at: datetime


class CandidatePoolListResponse(BaseModel):
    items: list[CandidateResponse]
    total: int


class CandidatePatch(BaseModel):
    """Partial update of the user-owned plan fields on a candidate.

    `note` distinguishes "absent" (leave alone) from explicit null (clear):
    the router inspects `model_fields_set`.
    """

    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1, description="Last seen version; server rejects on mismatch.")
    plan_status: PlanStatus | None = None
    note: str | None = None


class ReservedSlot(BaseModel):
    model_config = ConfigDict(extra="forbid")

    lane: SeasonLane
    month: str = Field(pattern=r"^\d{4}-(0[1-9]|1[0-2])$")
    note_cs: str | None = None


class ScenarioUpsert(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=120)
    description_cs: str | None = None
    rank: int = Field(ge=1)
    generated_at: datetime
    candidate_keys: list[str] = Field(max_length=200)
    reserved_slots: list[ReservedSlot] | None = None


class ScenariosPutRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    scenarios: list[ScenarioUpsert] = Field(max_length=12)
    replace: bool = True


class ScenarioResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    season_id: UUID
    name: str
    description_cs: str | None
    rank: int
    candidate_ids: list[UUID]
    reserved_slots: list[ReservedSlot] | None
    generated_at: datetime
    applied_at: datetime | None
    version: int
    created_at: datetime
    updated_at: datetime


class ScenarioListResponse(BaseModel):
    items: list[ScenarioResponse]


class ScenarioApplyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    mode: Literal["replace", "merge"] = "replace"


class PlanCounts(BaseModel):
    selected: int
    rejected: int
    undecided: int


class PlanWeek(BaseModel):
    iso_week: str
    count: int


class PlanSummaryResponse(BaseModel):
    selected: list[CandidateResponse]
    counts: PlanCounts
    weeks: list[PlanWeek]
    applied_scenario_id: UUID | None


class NoveltiesResponse(BaseModel):
    items: list[CandidateResponse]
    since_used: datetime
    now: datetime


class NoveltyAckRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    through: datetime


class SeasonBookedItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    title: str
    category: EventCategory
    starts_at: datetime


class SeasonBookedResponse(BaseModel):
    items: list[SeasonBookedItem]
