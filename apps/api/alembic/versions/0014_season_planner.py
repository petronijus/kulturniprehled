"""season planner

Revision ID: 0014
Revises: 0013
Create Date: 2026-08-09

Whole-season planning replaces the weekly-digest-only recommendation flow.
Three tables: `season_plans` (one row per cultural season, single active per
workspace), `season_candidates` (the scraped candidate pool with the user's
plan decision directly on the row — single user, one plan per season), and
`season_scenarios` (immutable skill-generated dramaturgies whose membership
is a JSONB UUID array; they are replaced wholesale on re-push, never queried
relationally). None of these participate in the mobile sync protocol — the
season planner is a web-only surface.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0014"
down_revision: str | None = "0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "season_plans",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("label", sa.String(20), nullable=False),
        sa.Column("starts_on", sa.Date(), nullable=False),
        sa.Column("ends_on", sa.Date(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("novelty_ack_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=False,
        ),
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
    )
    op.create_index(
        "uq_season_label",
        "season_plans",
        ["workspace_id", "label"],
        unique=True,
        postgresql_where=sa.text("deleted_at IS NULL"),
    )
    op.create_index(
        "uq_season_active",
        "season_plans",
        ["workspace_id"],
        unique=True,
        postgresql_where=sa.text("status = 'active' AND deleted_at IS NULL"),
    )

    op.create_table(
        "season_candidates",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "season_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("season_plans.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("dedup_key", sa.String(64), nullable=False),
        sa.Column("content_hash", sa.String(64), nullable=False),
        sa.Column("lane", sa.String(20), nullable=False),
        sa.Column("title", sa.String(255), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("venue", sa.String(255), nullable=True),
        sa.Column("url", sa.String(1024), nullable=True),
        sa.Column("price_czk", sa.String(40), nullable=True),
        sa.Column("program", postgresql.JSONB(), nullable=True),
        sa.Column("detail", postgresql.JSONB(), nullable=True),
        sa.Column("enriched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("score", sa.Float(), nullable=True),
        sa.Column("why_cs", sa.Text(), nullable=True),
        sa.Column("source_type", sa.String(20), nullable=True),
        sa.Column("source_name", sa.String(120), nullable=True),
        sa.Column("season_event", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("tickets_available", sa.Boolean(), nullable=True),
        sa.Column("plan_status", sa.String(20), nullable=False, server_default="undecided"),
        sa.Column("plan_status_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column(
            "first_seen_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "last_seen_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "created_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=False,
        ),
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
    )
    op.create_index(
        "uq_candidate_dedup",
        "season_candidates",
        ["season_id", "dedup_key"],
        unique=True,
        postgresql_where=sa.text("deleted_at IS NULL"),
    )
    op.create_index(
        "ix_season_candidates_starts",
        "season_candidates",
        ["season_id", "starts_at"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )
    op.create_index(
        "ix_season_candidates_plan_status",
        "season_candidates",
        ["season_id", "plan_status"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )
    op.create_index(
        "ix_season_candidates_first_seen",
        "season_candidates",
        ["season_id", "first_seen_at"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    op.create_table(
        "season_scenarios",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "season_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("season_plans.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "workspace_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("description_cs", sa.Text(), nullable=True),
        sa.Column("rank", sa.Integer(), nullable=False),
        sa.Column("candidate_ids", postgresql.JSONB(), nullable=False),
        sa.Column("reserved_slots", postgresql.JSONB(), nullable=True),
        sa.Column("generated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("applied_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="RESTRICT"),
            nullable=False,
        ),
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
    )
    op.create_index(
        "uq_scenario_name",
        "season_scenarios",
        ["season_id", "name"],
        unique=True,
        postgresql_where=sa.text("deleted_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_scenario_name", table_name="season_scenarios")
    op.drop_table("season_scenarios")
    op.drop_index("ix_season_candidates_first_seen", table_name="season_candidates")
    op.drop_index("ix_season_candidates_plan_status", table_name="season_candidates")
    op.drop_index("ix_season_candidates_starts", table_name="season_candidates")
    op.drop_index("uq_candidate_dedup", table_name="season_candidates")
    op.drop_table("season_candidates")
    op.drop_index("uq_season_active", table_name="season_plans")
    op.drop_index("uq_season_label", table_name="season_plans")
    op.drop_table("season_plans")
