"""event notifications

Revision ID: 0019
Revises: 0018
Create Date: 2026-10-26

Adds `event_notifications`: the server-side record that an event is worth a
notification on every member's phone (it was added, its venue or programme
changed, or a member asked for it). The phones used to infer "new event"
from an id they had not seen, which could never say "the programme
changed". Rows reach the phones through `change_log` like every other
synced entity; nothing is backfilled, so existing events stay silent.

Downgrade drops the table with its rows. Notifications are ephemeral — a
shown one is history, a pending one at most two minutes from due — so the
loss is accepted; the `change_log` entries stay and older clients ignore
the `notification` entity type.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0019"
down_revision: str | None = "0018"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "event_notifications",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "event_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("events.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("kind", sa.String(length=20), nullable=False),
        sa.Column(
            "changes",
            postgresql.ARRAY(sa.String(length=20)),
            nullable=False,
            server_default="{}",
        ),
        sa.Column("message", sa.Text(), nullable=True),
        sa.Column(
            "created_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("deliver_after", sa.DateTime(timezone=True), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index(
        "ix_event_notifications_event_pending",
        "event_notifications",
        ["event_id", "deliver_after"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_event_notifications_event_pending", table_name="event_notifications")
    op.drop_table("event_notifications")
