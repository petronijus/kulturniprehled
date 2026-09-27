"""season candidate content hash over the merged state

Revision ID: 0018
Revises: 0017
Create Date: 2026-09-28

A pool update used to replace every scraped field, so `content_hash` was the
hash of whatever payload arrived last. It is now a merge (omitted fields and
null enrichment keep their stored value) and the hash covers the row's
resulting state, with datetimes compared as instants.

Rows stored before that change carry a hash of the old form. Left alone,
every one of them would count as `updated` on the next push and bump its
`version` — which makes the planner's next edit of any row a version
conflict. This recomputes them from the stored values instead.

The hash is frozen here rather than imported from the API: a later change to
the runtime function must not rewrite what this migration did. The test
`test_migration_0018_hash_matches_runtime` holds the two together for as
long as the runtime form stays this one.

Downgrade is a no-op: the old hashes were of payloads nobody kept. Code from
before this change would see each row as changed once and move on.
"""

import hashlib
import json
from collections.abc import Mapping, Sequence
from datetime import UTC, datetime

import sqlalchemy as sa
from alembic import op

revision: str = "0018"
down_revision: str | None = "0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

CONTENT_FIELDS = (
    "lane",
    "title",
    "starts_at",
    "ends_at",
    "venue",
    "url",
    "price_czk",
    "program",
    "detail",
    "enriched_at",
    "score",
    "why_cs",
    "source_type",
    "source_name",
    "season_event",
    "tickets_available",
)


def _canonical(value: object) -> object:
    if isinstance(value, datetime):
        aware = value if value.tzinfo is not None else value.replace(tzinfo=UTC)
        return aware.astimezone(UTC).isoformat()
    return value


def content_hash(row: Mapping[str, object]) -> str:
    payload = {field: _canonical(row[field]) for field in CONTENT_FIELDS}
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def upgrade() -> None:
    candidates = sa.table(
        "season_candidates",
        sa.column("id"),
        sa.column("content_hash"),
        *(sa.column(field) for field in CONTENT_FIELDS),
    )
    bind = op.get_bind()
    select = sa.select(candidates.c.id, *(candidates.c[field] for field in CONTENT_FIELDS))
    for row in bind.execute(select).mappings().all():
        values = {field: row[field] for field in CONTENT_FIELDS}
        bind.execute(
            candidates.update()
            .where(candidates.c.id == row["id"])
            .values(content_hash=content_hash(values))
        )


def downgrade() -> None:
    pass
