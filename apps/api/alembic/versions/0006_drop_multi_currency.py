"""drop multi-currency: remove fx_rates, costs.currency

Revision ID: 0006
Revises: 0005
Create Date: 2026-05-14

Everything is in Czech crowns. The FX cache was overkill for a household
ledger — strip it so the schema and the read path stay simple. Amounts
stay in `amount_cents` because Decimal in the row is still preferable to
floats.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_column("costs", "currency")
    op.drop_table("fx_rates")


def downgrade() -> None:
    op.create_table(
        "fx_rates",
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
    op.add_column(
        "costs",
        sa.Column(
            "currency",
            sa.String(3),
            nullable=False,
            server_default="CZK",
        ),
    )
    _ = postgresql  # quiet linter — kept for future column additions
