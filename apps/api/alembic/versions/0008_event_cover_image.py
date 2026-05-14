"""event cover image

Revision ID: 0008
Revises: 0007
Create Date: 2026-05-14

Adds an optional `cover_image_url` to `events`. Used by the mobile app to
render a hero image in the event detail screen. Nullable so existing rows
don't need a backfill.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "events",
        sa.Column("cover_image_url", sa.String(length=1024), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("events", "cover_image_url")
