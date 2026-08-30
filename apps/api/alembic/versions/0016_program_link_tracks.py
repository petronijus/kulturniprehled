"""programme link track uris

Revision ID: 0016
Revises: 0015
Create Date: 2026-08-30

A classical work is several tracks (movements), so "where to listen to this
piece" is a list of track URIs, not one link. The album URL stays as the
human-facing link; the URIs are what the planner's inline player queues.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0016"
down_revision: str | None = "0015"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "program_media_links",
        sa.Column("spotify_track_uris", postgresql.JSONB(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("program_media_links", "spotify_track_uris")
