"""event departure_at

Revision ID: 0010
Revises: 0009
Create Date: 2026-05-21

Adds optional `departure_at` (UTC timestamptz) to `events`. The ingest
skill computes this as `starts_at - 15 min - journey_time` from the
home address; the mobile app uses it to schedule a "leave in 10 min"
local notification. Nullable because journey-time lookup may fail or
be skipped entirely (e.g. cottage event), and we still want the row.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "events",
        sa.Column(
            "departure_at",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("events", "departure_at")
