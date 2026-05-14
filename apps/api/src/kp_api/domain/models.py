"""SQLAlchemy 2.0 ORM models for the Kulturní Přehled domain.

This file defines the core entities introduced in milestone M1
(users, workspaces, events, venues, change_log). Sync write-side hooks for
`change_log` arrive in M2; the table is created here so migrations stay
linear and so the `seq` column already exists when M2 ships.

Conventions:
- Primary keys are UUIDv7 generated in Python (`domain.ids.uuid7`) — they
  sort chronologically, which gives Postgres better index locality.
- Timestamps are `TIMESTAMPTZ` and default to `now()` at the database.
- Soft deletes use `deleted_at`; queries must filter it out.
- `version` is an optimistic-locking counter — server increments on every
  upsert, clients must echo the value they last saw.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PG_UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

from kp_api.domain.enums import (
    ChangeOp,
    CostKind,
    CostSplit,
    EventCategory,
    EventSource,
    EventStatus,
    UserRole,
    WatchlistKind,
)
from kp_api.domain.ids import uuid7


class Base(DeclarativeBase):
    pass


def _uuid_pk() -> Mapped[UUID]:
    return mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        default=uuid7,
    )


def _created_at() -> Mapped[datetime]:
    return mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


def _python_utcnow() -> datetime:
    return datetime.now(UTC)


def _updated_at() -> Mapped[datetime]:
    # onupdate runs Python-side: SQLAlchemy materializes the value and
    # includes it in the UPDATE statement, so the in-memory attribute stays
    # fresh. Using `func.now()` here would mark the attribute expired and
    # force a reload — which then explodes in async sessions because the
    # lazy fetch happens outside SQLAlchemy's `greenlet_spawn` context.
    return mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=_python_utcnow,
    )


class User(Base):
    __tablename__ = "users"

    id: Mapped[UUID] = _uuid_pk()
    email: Mapped[str] = mapped_column(String(320), nullable=False, unique=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    role: Mapped[UserRole] = mapped_column(String(20), nullable=False, default=UserRole.MEMBER)
    google_refresh_token: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = _created_at()
    updated_at: Mapped[datetime] = _updated_at()

    memberships: Mapped[list[WorkspaceMember]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class Workspace(Base):
    __tablename__ = "workspaces"

    id: Mapped[UUID] = _uuid_pk()
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    google_calendar_id: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = _created_at()
    updated_at: Mapped[datetime] = _updated_at()

    members: Mapped[list[WorkspaceMember]] = relationship(
        back_populates="workspace", cascade="all, delete-orphan"
    )
    events: Mapped[list[Event]] = relationship(back_populates="workspace")


class WorkspaceMember(Base):
    __tablename__ = "workspace_members"
    __table_args__ = (UniqueConstraint("workspace_id", "user_id", name="uq_workspace_members"),)

    id: Mapped[UUID] = _uuid_pk()
    workspace_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    role: Mapped[UserRole] = mapped_column(String(20), nullable=False, default=UserRole.MEMBER)
    created_at: Mapped[datetime] = _created_at()

    workspace: Mapped[Workspace] = relationship(back_populates="members")
    user: Mapped[User] = relationship(back_populates="memberships")


class Venue(Base):
    __tablename__ = "venues"

    id: Mapped[UUID] = _uuid_pk()
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    address: Mapped[str | None] = mapped_column(Text, nullable=True)
    city: Mapped[str | None] = mapped_column(String(120), nullable=True)
    country: Mapped[str | None] = mapped_column(String(80), nullable=True)
    lat: Mapped[float | None] = mapped_column(nullable=True)
    lng: Mapped[float | None] = mapped_column(nullable=True)
    created_at: Mapped[datetime] = _created_at()


class Event(Base):
    __tablename__ = "events"
    __table_args__ = (
        Index("ix_events_workspace_starts_at", "workspace_id", "starts_at"),
        Index(
            "ix_events_workspace_active",
            "workspace_id",
            "deleted_at",
            postgresql_where="deleted_at IS NULL",
        ),
    )

    id: Mapped[UUID] = _uuid_pk()
    workspace_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="RESTRICT"),
        nullable=False,
    )
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    category: Mapped[EventCategory] = mapped_column(String(20), nullable=False)
    venue_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("venues.id", ondelete="SET NULL"),
        nullable=True,
    )
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ends_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    venue_timezone: Mapped[str | None] = mapped_column(String(60), nullable=True)
    status: Mapped[EventStatus] = mapped_column(
        String(20), nullable=False, default=EventStatus.PLANNED
    )
    source: Mapped[EventSource] = mapped_column(
        String(20), nullable=False, default=EventSource.MANUAL
    )
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_by: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="RESTRICT"),
        nullable=False,
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = _created_at()
    updated_at: Mapped[datetime] = _updated_at()
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    workspace: Mapped[Workspace] = relationship(back_populates="events")
    venue: Mapped[Venue | None] = relationship()


class Ticket(Base):
    """A purchased-ticket artefact attached to an event.

    The blob (PDF / image / ICS file) lives in MinIO at `object_key`. The
    domain row carries identity, integrity (`hash_sha256`) and provenance
    (`uploaded_by`); the bytes themselves are fetched via a short-lived
    presigned URL. `workspace_id` is denormalized from the parent event so
    sync queries do not have to join."""

    __tablename__ = "tickets"
    __table_args__ = (
        Index(
            "ix_tickets_event_active",
            "event_id",
            "deleted_at",
            postgresql_where="deleted_at IS NULL",
        ),
        Index(
            "ix_tickets_workspace_active",
            "workspace_id",
            "deleted_at",
            postgresql_where="deleted_at IS NULL",
        ),
    )

    id: Mapped[UUID] = _uuid_pk()
    event_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("events.id", ondelete="CASCADE"),
        nullable=False,
    )
    workspace_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="RESTRICT"),
        nullable=False,
    )
    object_key: Mapped[str] = mapped_column(String(512), nullable=False, unique=True)
    mime_type: Mapped[str] = mapped_column(String(120), nullable=False)
    original_filename: Mapped[str | None] = mapped_column(String(255), nullable=True)
    size_bytes: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    hash_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    uploaded_by: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="RESTRICT"),
        nullable=False,
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = _created_at()
    updated_at: Mapped[datetime] = _updated_at()
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class Cost(Base):
    """A money line attached to an event.

    Amounts are stored in minor units (haléře) as integers — implicit
    currency is CZK, the only currency the household tracks. Multi-currency
    support was removed in 0006 along with the frankfurter FX cache; if
    the day ever comes that we need foreign currencies again, restore the
    `currency` column and re-introduce a conversion table.
    """

    __tablename__ = "costs"
    __table_args__ = (
        CheckConstraint("amount_cents >= 0", name="ck_costs_amount_nonnegative"),
        Index("ix_costs_workspace_paid_at", "workspace_id", "paid_at"),
        Index(
            "ix_costs_event_active",
            "event_id",
            "deleted_at",
            postgresql_where="deleted_at IS NULL",
        ),
    )

    id: Mapped[UUID] = _uuid_pk()
    event_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("events.id", ondelete="CASCADE"),
        nullable=False,
    )
    workspace_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="RESTRICT"),
        nullable=False,
    )
    amount_cents: Mapped[int] = mapped_column(BigInteger, nullable=False)
    kind: Mapped[CostKind] = mapped_column(String(20), nullable=False)
    paid_by: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="RESTRICT"),
        nullable=False,
    )
    split: Mapped[CostSplit] = mapped_column(String(20), nullable=False, default=CostSplit.SHARED)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    paid_at: Mapped[date] = mapped_column(Date, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = _created_at()
    updated_at: Mapped[datetime] = _updated_at()
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class WatchlistItem(Base):
    """An item in the shared watchlist: a film / concert / play we want to
    catch later. Items can nest one level under a parent item ("Godard" with
    four films beneath it). Order within a parent (or at the root) is
    controlled by `position`, a float interpolated between neighbours on
    insert/move — only the moved row changes, which keeps sync chatter low.

    Cascade rules: parents and their children are independent rows. Deleting
    a parent soft-deletes its non-deleted children in the same transaction
    (handled in the repository / outbox path, not via DB ON DELETE — we never
    hard-delete).
    """

    __tablename__ = "watchlist_items"
    __table_args__ = (
        Index(
            "ix_watchlist_workspace_parent_pos",
            "workspace_id",
            "parent_id",
            "position",
            postgresql_where="deleted_at IS NULL",
        ),
        Index(
            "ix_watchlist_workspace_active",
            "workspace_id",
            "deleted_at",
            postgresql_where="deleted_at IS NULL",
        ),
    )

    id: Mapped[UUID] = _uuid_pk()
    workspace_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="RESTRICT"),
        nullable=False,
    )
    parent_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("watchlist_items.id", ondelete="RESTRICT"),
        nullable=True,
    )
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    kind: Mapped[WatchlistKind] = mapped_column(String(20), nullable=False)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    position: Mapped[float] = mapped_column(nullable=False)
    done: Mapped[bool] = mapped_column(nullable=False, default=False)
    done_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    done_by: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    created_by: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="RESTRICT"),
        nullable=False,
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = _created_at()
    updated_at: Mapped[datetime] = _updated_at()
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class PersonalAccessToken(Base):
    """Long-lived bearer credential for headless clients (Claude Code skill,
    desktop scripts).

    Unlike refresh tokens, a PAT is presented directly on every request and
    never rotates. We sign it as a JWT so verification is stateless; the row
    here only exists for naming, revocation, and `last_used_at` book-keeping."""

    __tablename__ = "personal_access_tokens"

    jti: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    created_at: Mapped[datetime] = _created_at()
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class RefreshToken(Base):
    """Issued refresh tokens. Reuse detection: when a token is presented after
    being rotated, the whole family is revoked. `family_id` ties all tokens
    that descend from one login together; `parent_jti` links to the token this
    one replaced (NULL for the root token of a family)."""

    __tablename__ = "refresh_tokens"

    jti: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    family_id: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), nullable=False)
    parent_jti: Mapped[UUID | None] = mapped_column(PG_UUID(as_uuid=True), nullable=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    rotated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = _created_at()


class ChangeLog(Base):
    """Append-only monotonic log used by the sync protocol.

    Mobile clients pull with `GET /v1/sync?since=<seq>`. `seq` is the only
    cursor that matters; timestamps are recorded for observability. The
    `workspace_id` column scopes the cursor — a member only sees changes for
    workspaces they belong to."""

    __tablename__ = "change_log"
    __table_args__ = (CheckConstraint("seq > 0", name="ck_change_log_seq_positive"),)

    seq: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    workspace_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="RESTRICT"),
        nullable=False,
    )
    entity_type: Mapped[str] = mapped_column(String(40), nullable=False)
    entity_id: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), nullable=False)
    op: Mapped[ChangeOp] = mapped_column(String(10), nullable=False)
    payload: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    actor_id: Mapped[UUID | None] = mapped_column(PG_UUID(as_uuid=True), nullable=True)
    created_at: Mapped[datetime] = _created_at()


class AppliedOp(Base):
    """Idempotency cache for `POST /v1/sync/apply`.

    Clients generate an `op_id` UUID for each mutation in their outbox; the
    server stores the response on first apply and replays it on retry so a
    flaky network never produces a duplicate event."""

    __tablename__ = "applied_ops"

    op_id: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), primary_key=True)
    actor_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    workspace_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    response: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = _created_at()
