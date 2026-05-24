"""recommendation feedback

Revision ID: 0011
Revises: 0010
Create Date: 2026-05-24

Per-event thumbs-up/down feedback from the weekly digest email. Links
in the email carry an HMAC-signed token so the endpoint needs no login.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "recommendation_feedback",
        sa.Column("id", sa.dialects.postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("event_title", sa.String(255), nullable=False),
        sa.Column("event_lane", sa.String(40), nullable=False),
        sa.Column("digest_week", sa.String(10), nullable=False),
        sa.Column("rating", sa.String(10), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index(
        "ix_rec_feedback_lane_week",
        "recommendation_feedback",
        ["event_lane", "digest_week"],
    )


def downgrade() -> None:
    op.drop_index("ix_rec_feedback_lane_week", table_name="recommendation_feedback")
    op.drop_table("recommendation_feedback")
