"""sync infrastructure: workspace-scoped change_log + applied_ops idempotency

Revision ID: 0002
Revises: 0001
Create Date: 2026-05-13

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # The change_log table is created empty in 0001 — no backfill needed,
    # we can add a NOT NULL workspace_id column outright.
    op.add_column(
        "change_log",
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="RESTRICT"),
            nullable=False,
        ),
    )
    op.create_index(
        "ix_change_log_workspace_seq",
        "change_log",
        ["workspace_id", "seq"],
    )

    # Idempotency cache for POST /v1/sync/apply. A client retrying the same
    # op_id receives the cached response instead of re-applying.
    op.create_table(
        "applied_ops",
        sa.Column("op_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "actor_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("response", postgresql.JSONB(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index(
        "ix_applied_ops_workspace_created",
        "applied_ops",
        ["workspace_id", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_applied_ops_workspace_created", table_name="applied_ops")
    op.drop_table("applied_ops")
    op.drop_index("ix_change_log_workspace_seq", table_name="change_log")
    op.drop_column("change_log", "workspace_id")
