"""ticket codes

Revision ID: 0020
Revises: 0019
Create Date: 2026-11-22

Adds `tickets.codes`: the QR / Aztec / PDF417 / linear barcodes the server
found in the ticket blob, so the phones can show them in the event detail
without opening the PDF. NULL means "not scanned yet"; existing tickets are
filled in by `python -m kp_api.cli scan-ticket-codes` after the upgrade.

Downgrade drops the column; the codes can be decoded again from the blobs.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0020"
down_revision: str | None = "0019"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("tickets", sa.Column("codes", postgresql.JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column("tickets", "codes")
