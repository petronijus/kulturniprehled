"""event spotify_playlist_url

Revision ID: 0013
Revises: 0012
Create Date: 2026-06-03

Adds optional `spotify_playlist_url` to `events`. The ingest skill builds a
public Spotify playlist previewing the concert program and PATCHes the URL
here; the mobile app renders a "Playlist" link from it. The stored URL also
serves as the idempotency key — a re-run updates the existing playlist
instead of creating a duplicate. Nullable: non-concert events and Spotify
failures leave it empty.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "events",
        sa.Column("spotify_playlist_url", sa.String(length=1024), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("events", "spotify_playlist_url")
