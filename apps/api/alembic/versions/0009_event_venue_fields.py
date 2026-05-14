"""event venue image + address

Revision ID: 0009
Revises: 0008
Create Date: 2026-05-15

Adds optional `venue_image_url` and `venue_address` to `events`. Both are
nullable so existing rows don't need a backfill. We denormalise rather than
populating the `venues` table because every event in this codebase is
created without a venue row today, and ticket-flow events rarely share a
venue cleanly enough to warrant the join. If we ever start filtering by
venue, migrating these strings into the `venues` table is a follow-up.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "events",
        sa.Column("venue_image_url", sa.String(length=1024), nullable=True),
    )
    op.add_column(
        "events",
        sa.Column("venue_address", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("events", "venue_address")
    op.drop_column("events", "venue_image_url")
