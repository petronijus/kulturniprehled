"""program media links

Revision ID: 0015
Revises: 0014
Create Date: 2026-08-30

One row per programme piece (folded `author|work`), holding where to listen
to it. Deliberately not a column on `season_candidates`: the same work
recurs across many candidates, and a pool upsert rewrites a candidate's
`program` wholesale — links stored there would be lost on every re-scrape.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0015"
down_revision: str | None = "0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "program_media_links",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("key", sa.String(400), nullable=False),
        sa.Column("author", sa.String(255), nullable=True),
        sa.Column("work", sa.String(400), nullable=True),
        sa.Column("spotify_url", sa.String(1024), nullable=True),
        sa.Column("youtube_url", sa.String(1024), nullable=True),
        sa.Column("match_label", sa.String(400), nullable=True),
        sa.Column(
            "resolved_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
    )
    op.create_index(
        "uq_program_media_link_key",
        "program_media_links",
        ["workspace_id", "key"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("uq_program_media_link_key", table_name="program_media_links")
    op.drop_table("program_media_links")
