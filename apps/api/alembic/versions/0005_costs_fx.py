"""costs + fx_rates

Revision ID: 0005
Revises: 0004
Create Date: 2026-05-14

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "costs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "event_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("events.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("amount_cents", sa.BigInteger(), nullable=False),
        # ISO 4217 alpha-3.
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column(
            "paid_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("split", sa.String(20), nullable=False, server_default="shared"),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("paid_at", sa.Date(), nullable=False),
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
        sa.CheckConstraint(
            "amount_cents >= 0", name="ck_costs_amount_nonnegative"
        ),
    )
    op.create_index(
        "ix_costs_workspace_paid_at",
        "costs",
        ["workspace_id", "paid_at"],
    )
    op.create_index(
        "ix_costs_event_active",
        "costs",
        ["event_id", "deleted_at"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    op.create_table(
        "fx_rates",
        # Daily mid-rate from frankfurter.app cached locally so we don't ping
        # them per request and so historic reports stay stable.
        sa.Column("date", sa.Date(), primary_key=True),
        sa.Column("base", sa.String(3), primary_key=True),
        sa.Column("quote", sa.String(3), primary_key=True),
        sa.Column("rate", sa.Numeric(18, 8), nullable=False),
        sa.Column(
            "fetched_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )


def downgrade() -> None:
    op.drop_table("fx_rates")
    op.drop_index("ix_costs_event_active", table_name="costs")
    op.drop_index("ix_costs_workspace_paid_at", table_name="costs")
    op.drop_table("costs")
