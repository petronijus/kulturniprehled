"""Season-planner REST endpoints.

The season planner is a web-only surface (no mobile sync): a skill pushes a
season-wide candidate pool plus ~5 scenario dramaturgies, Petr finalizes his
plan in the SPA, and a weekly routine reads/acks novelties.

Two authorization scopes gate the surface: `season:read` for all reads and
`season:write` for pool/scenario ingest and plan mutations. Unrestricted
credentials (interactive JWT, unscoped PAT) pass both.

Ingest invariant (the contract the whole feature rests on): a pool upsert
refreshes scraped fields and always bumps `last_seen_at`, bumps `version`
only when the content hash changed, and never touches the user-owned fields
(`first_seen_at`, `plan_status`, `plan_status_at`, `note`).
"""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, date, datetime, time, timedelta
from typing import Annotated
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.calendar_ics import (
    CalendarView,
    HolidayView,
    fetch_calendar_view,
    fetch_holidays,
)
from kp_api.api.deps import SessionDep, SettingsDep, require_scope
from kp_api.domain.enums import PlanStatus, SeasonLane, SeasonStatus
from kp_api.domain.models import (
    Event,
    SeasonCandidate,
    SeasonPlan,
    SeasonScenario,
    User,
    Workspace,
    WorkspaceMember,
)
from kp_api.domain.schemas import (
    CandidatePatch,
    CandidatePoolListResponse,
    CandidateResponse,
    CandidateUpsert,
    NoveltiesResponse,
    NoveltyAckRequest,
    PlanCounts,
    PlanSummaryResponse,
    PlanWeek,
    ScenarioApplyRequest,
    ScenarioListResponse,
    ScenarioResponse,
    ScenariosPutRequest,
    SeasonBookedItem,
    SeasonBookedResponse,
    SeasonCreate,
    SeasonListResponse,
    SeasonPoolPutRequest,
    SeasonPoolPutResult,
    SeasonResponse,
)
from kp_api.domain.scopes import SCOPE_SEASON_READ, SCOPE_SEASON_WRITE

router = APIRouter(prefix="/v1/season", tags=["season"])

SeasonReader = Annotated[User, Depends(require_scope(SCOPE_SEASON_READ))]
SeasonWriter = Annotated[User, Depends(require_scope(SCOPE_SEASON_WRITE))]

# Events are Prague events; ISO-week bucketing must follow the local wall
# calendar, not UTC (a 00:30 CEST concert belongs to its local date's week).
_PRAGUE = ZoneInfo("Europe/Prague")

# A season plus its shoulder months; wider windows are a caller bug, and each
# one costs a full recurrence expansion.
_CALENDAR_MAX_RANGE_DAYS = 400


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _calendar_window(range_start: date | None, range_end: date | None) -> tuple[date, date]:
    """Validate and default the feed window shared by the calendar endpoints.

    Defaults to the next 180 days — the digest horizon.
    """

    today = datetime.now(tz=_PRAGUE).date()
    start = range_start or today
    end = range_end or today + timedelta(days=180)
    if end < start:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"code": "invalid_range", "message": "`to` precedes `from`"},
        )
    if (end - start).days > _CALENDAR_MAX_RANGE_DAYS:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={
                "code": "range_too_wide",
                "message": f"window exceeds {_CALENDAR_MAX_RANGE_DAYS} days",
            },
        )
    return start, end


def _iso_week(moment: datetime) -> str:
    return moment.astimezone(_PRAGUE).strftime("%G-W%V")


async def _user_workspace(session: AsyncSession, user: User) -> Workspace:
    workspace = await session.scalar(
        select(Workspace)
        .join(WorkspaceMember, WorkspaceMember.workspace_id == Workspace.id)
        .where(WorkspaceMember.user_id == user.id)
        .limit(1)
    )
    if workspace is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "user has no workspace")
    return workspace


async def _get_active_season(
    session: AsyncSession, workspace: Workspace, season_id: UUID
) -> SeasonPlan:
    season = await session.scalar(
        select(SeasonPlan).where(
            SeasonPlan.id == season_id,
            SeasonPlan.workspace_id == workspace.id,
            SeasonPlan.deleted_at.is_(None),
        )
    )
    if season is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "season not found")
    return season


def _matches_veto(venue: str | None, source_name: str | None, veto: tuple[str, ...]) -> bool:
    haystack = f"{venue or ''} {source_name or ''}".casefold()
    return any(term in haystack for term in veto)


def _is_vetoed_venue(item: CandidateUpsert, veto: tuple[str, ...]) -> bool:
    return bool(veto) and _matches_veto(item.venue, item.source_name, veto)


async def _purge_vetoed(session: AsyncSession, season: SeasonPlan, veto: tuple[str, ...]) -> int:
    """Soft-delete pool rows sitting at a vetoed venue. Returns the count.

    Runs on every ingest so a newly added veto cleans up after itself. Only
    the pool is touched — a candidate already promoted to a booked event
    lives in `events` and is out of scope here.
    """

    if not veto:
        return 0
    rows = await session.scalars(
        select(SeasonCandidate).where(
            SeasonCandidate.season_id == season.id,
            SeasonCandidate.deleted_at.is_(None),
        )
    )
    now = _utcnow()
    purged = 0
    for row in rows.all():
        if _matches_veto(row.venue, row.source_name, veto):
            row.deleted_at = now
            row.version += 1
            purged += 1
    return purged


def _content_hash(item: CandidateUpsert) -> str:
    """Deterministic hash over the scraped fields.

    `dedup_key` is excluded — it is the identity, not the content. JSON mode
    dump turns datetimes into ISO strings so serialization is stable.
    """

    payload = item.model_dump(mode="json", exclude={"dedup_key"})
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


# Scraped columns refreshed on every content change. Deliberately excludes
# the user-owned plan fields and the bookkeeping columns.
_SCRAPED_FIELDS = (
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


@router.post("/plans", response_model=SeasonResponse, status_code=status.HTTP_201_CREATED)
async def create_season(
    body: SeasonCreate,
    session: SessionDep,
    user: SeasonWriter,
) -> SeasonResponse:
    workspace = await _user_workspace(session, user)
    if body.ends_on <= body.starts_on:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            {"code": "invalid_season_window", "detail": "ends_on must be after starts_on"},
        )

    current = await session.scalar(
        select(SeasonPlan).where(
            SeasonPlan.workspace_id == workspace.id,
            SeasonPlan.status == SeasonStatus.ACTIVE,
            SeasonPlan.deleted_at.is_(None),
        )
    )
    if current is not None:
        if not body.archive_current:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                {"code": "active_season_exists", "current_label": current.label},
            )
        # Explicit handover: archive in the same transaction so the partial
        # unique index never sees two active rows.
        current.status = SeasonStatus.ARCHIVED
        current.version += 1
        await session.flush()

    season = SeasonPlan(
        workspace_id=workspace.id,
        label=body.label,
        starts_on=body.starts_on,
        ends_on=body.ends_on,
        status=SeasonStatus.ACTIVE,
        created_by=user.id,
        version=1,
    )
    session.add(season)
    await session.commit()
    await session.refresh(season)
    return SeasonResponse.model_validate(season)


@router.get("/plans", response_model=SeasonListResponse)
async def list_seasons(
    session: SessionDep,
    user: SeasonReader,
) -> SeasonListResponse:
    workspace = await _user_workspace(session, user)
    rows = await session.scalars(
        select(SeasonPlan)
        .where(
            SeasonPlan.workspace_id == workspace.id,
            SeasonPlan.deleted_at.is_(None),
        )
        .order_by(SeasonPlan.starts_on.desc())
    )
    items = [SeasonResponse.model_validate(s) for s in rows.all()]
    return SeasonListResponse(items=items, total=len(items))


@router.get("/plans/current", response_model=SeasonResponse)
async def current_season(
    session: SessionDep,
    user: SeasonReader,
) -> SeasonResponse:
    workspace = await _user_workspace(session, user)
    season = await session.scalar(
        select(SeasonPlan).where(
            SeasonPlan.workspace_id == workspace.id,
            SeasonPlan.status == SeasonStatus.ACTIVE,
            SeasonPlan.deleted_at.is_(None),
        )
    )
    if season is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no active season")
    return SeasonResponse.model_validate(season)


@router.put("/plans/{season_id}/pool", response_model=SeasonPoolPutResult)
async def put_pool(
    season_id: UUID,
    body: SeasonPoolPutRequest,
    session: SessionDep,
    settings: SettingsDep,
    user: SeasonWriter,
) -> SeasonPoolPutResult:
    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)

    veto = settings.season_venue_veto_terms
    # Last occurrence wins on duplicate keys within one payload — a scrape
    # merging several sources can legitimately see the same event twice.
    by_key: dict[str, CandidateUpsert] = {
        item.dedup_key: item for item in body.items if not _is_vetoed_venue(item, veto)
    }
    vetoed = len(body.items) - len(by_key)
    # The veto is retroactive: candidates ingested before a venue was vetoed
    # (or before this backstop existed) disappear on the next scrape instead
    # of lingering in the pool forever.
    purged = await _purge_vetoed(session, season, veto)

    existing_rows = await session.scalars(
        select(SeasonCandidate).where(
            SeasonCandidate.season_id == season.id,
            SeasonCandidate.dedup_key.in_(by_key.keys()),
            SeasonCandidate.deleted_at.is_(None),
        )
    )
    existing = {row.dedup_key: row for row in existing_rows.all()}

    now = _utcnow()
    created = updated = unchanged = 0
    for key, item in by_key.items():
        digest = _content_hash(item)
        row = existing.get(key)
        if row is None:
            data = item.model_dump()
            candidate = SeasonCandidate(
                season_id=season.id,
                workspace_id=workspace.id,
                content_hash=digest,
                created_by=user.id,
                version=1,
                first_seen_at=now,
                last_seen_at=now,
                **data,
            )
            session.add(candidate)
            created += 1
        elif row.content_hash == digest:
            row.last_seen_at = now
            unchanged += 1
        else:
            for field in _SCRAPED_FIELDS:
                setattr(row, field, getattr(item, field))
            row.content_hash = digest
            row.last_seen_at = now
            row.version += 1
            updated += 1

    await session.commit()
    return SeasonPoolPutResult(
        created=created,
        updated=updated,
        unchanged=unchanged,
        total=len(by_key),
        vetoed=vetoed,
        purged=purged,
    )


@router.get("/plans/{season_id}/pool", response_model=CandidatePoolListResponse)
async def list_pool(
    season_id: UUID,
    session: SessionDep,
    user: SeasonReader,
    lane: Annotated[SeasonLane | None, Query()] = None,
    plan_status: Annotated[PlanStatus | None, Query()] = None,
    starts_from: Annotated[datetime | None, Query()] = None,
    starts_to: Annotated[datetime | None, Query()] = None,
    new_since: Annotated[datetime | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=120)] = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> CandidatePoolListResponse:
    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)

    base = select(SeasonCandidate).where(
        SeasonCandidate.season_id == season.id,
        SeasonCandidate.deleted_at.is_(None),
    )
    if lane is not None:
        base = base.where(SeasonCandidate.lane == lane)
    if plan_status is not None:
        base = base.where(SeasonCandidate.plan_status == plan_status)
    if starts_from is not None:
        base = base.where(SeasonCandidate.starts_at >= starts_from)
    if starts_to is not None:
        base = base.where(SeasonCandidate.starts_at < starts_to)
    if new_since is not None:
        base = base.where(SeasonCandidate.first_seen_at > new_since)
    if q is not None:
        base = base.where(SeasonCandidate.title.ilike(f"%{q}%"))

    total = await session.scalar(select(func.count()).select_from(base.subquery()))
    rows = await session.scalars(
        base.order_by(SeasonCandidate.starts_at.asc()).offset(offset).limit(limit)
    )
    return CandidatePoolListResponse(
        items=[CandidateResponse.model_validate(c) for c in rows.all()],
        total=int(total or 0),
    )


@router.put("/plans/{season_id}/scenarios", response_model=ScenarioListResponse)
async def put_scenarios(
    season_id: UUID,
    body: ScenariosPutRequest,
    session: SessionDep,
    user: SeasonWriter,
) -> ScenarioListResponse:
    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)

    wanted_keys = {key for scenario in body.scenarios for key in scenario.candidate_keys}
    key_rows = await session.execute(
        select(SeasonCandidate.dedup_key, SeasonCandidate.id).where(
            SeasonCandidate.season_id == season.id,
            SeasonCandidate.dedup_key.in_(wanted_keys),
            SeasonCandidate.deleted_at.is_(None),
        )
    )
    key_to_id = {key: cid for key, cid in key_rows.all()}
    unknown = sorted(wanted_keys - key_to_id.keys())
    if unknown:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            {"code": "unknown_candidate_keys", "keys": unknown},
        )

    existing_rows = await session.scalars(
        select(SeasonScenario).where(
            SeasonScenario.season_id == season.id,
            SeasonScenario.deleted_at.is_(None),
        )
    )
    existing = {row.name: row for row in existing_rows.all()}

    now = _utcnow()
    kept: list[SeasonScenario] = []
    for spec in body.scenarios:
        candidate_ids = [str(key_to_id[key]) for key in spec.candidate_keys]
        slots = (
            [slot.model_dump() for slot in spec.reserved_slots]
            if spec.reserved_slots is not None
            else None
        )
        row = existing.get(spec.name)
        if row is None:
            row = SeasonScenario(
                season_id=season.id,
                workspace_id=workspace.id,
                name=spec.name,
                description_cs=spec.description_cs,
                rank=spec.rank,
                candidate_ids=candidate_ids,
                reserved_slots=slots,
                generated_at=spec.generated_at,
                created_by=user.id,
                version=1,
            )
            session.add(row)
        else:
            row.description_cs = spec.description_cs
            row.rank = spec.rank
            row.candidate_ids = candidate_ids
            row.reserved_slots = slots
            row.generated_at = spec.generated_at
            row.version += 1
        kept.append(row)

    if body.replace:
        pushed_names = {spec.name for spec in body.scenarios}
        for name, row in existing.items():
            if name not in pushed_names:
                row.deleted_at = now
                row.version += 1

    await session.commit()
    for row in kept:
        await session.refresh(row)
    kept.sort(key=lambda r: r.rank)
    return ScenarioListResponse(items=[ScenarioResponse.model_validate(r) for r in kept])


@router.get("/plans/{season_id}/scenarios", response_model=ScenarioListResponse)
async def list_scenarios(
    season_id: UUID,
    session: SessionDep,
    user: SeasonReader,
) -> ScenarioListResponse:
    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)
    rows = await session.scalars(
        select(SeasonScenario)
        .where(
            SeasonScenario.season_id == season.id,
            SeasonScenario.deleted_at.is_(None),
        )
        .order_by(SeasonScenario.rank.asc())
    )
    return ScenarioListResponse(items=[ScenarioResponse.model_validate(r) for r in rows.all()])


async def _plan_summary(session: AsyncSession, season: SeasonPlan) -> PlanSummaryResponse:
    rows = await session.scalars(
        select(SeasonCandidate).where(
            SeasonCandidate.season_id == season.id,
            SeasonCandidate.deleted_at.is_(None),
        )
    )
    candidates = rows.all()

    counts = {status_: 0 for status_ in PlanStatus}
    for candidate in candidates:
        counts[PlanStatus(candidate.plan_status)] += 1

    selected = sorted(
        (c for c in candidates if c.plan_status == PlanStatus.SELECTED),
        key=lambda c: c.starts_at,
    )
    weeks: dict[str, int] = {}
    for candidate in selected:
        week = _iso_week(candidate.starts_at)
        weeks[week] = weeks.get(week, 0) + 1

    last_applied = await session.scalar(
        select(SeasonScenario)
        .where(
            SeasonScenario.season_id == season.id,
            SeasonScenario.deleted_at.is_(None),
            SeasonScenario.applied_at.is_not(None),
        )
        .order_by(SeasonScenario.applied_at.desc())
        .limit(1)
    )

    return PlanSummaryResponse(
        selected=[CandidateResponse.model_validate(c) for c in selected],
        counts=PlanCounts(
            selected=counts[PlanStatus.SELECTED],
            rejected=counts[PlanStatus.REJECTED],
            undecided=counts[PlanStatus.UNDECIDED],
        ),
        weeks=[PlanWeek(iso_week=week, count=n) for week, n in sorted(weeks.items())],
        applied_scenario_id=last_applied.id if last_applied is not None else None,
    )


@router.get("/plans/{season_id}/plan", response_model=PlanSummaryResponse)
async def plan_summary(
    season_id: UUID,
    session: SessionDep,
    user: SeasonReader,
) -> PlanSummaryResponse:
    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)
    return await _plan_summary(session, season)


@router.get("/plans/{season_id}/booked", response_model=SeasonBookedResponse)
async def booked_events(
    season_id: UUID,
    session: SessionDep,
    user: SeasonReader,
) -> SeasonBookedResponse:
    """Already-booked KP events inside the season window.

    Served under the season scope so the login-less planner (trusted-LAN
    principal) can feed the week-cap and gap rules without access to the
    general `/v1/events` surface.
    """

    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)
    window_start = datetime.combine(season.starts_on, time.min, tzinfo=_PRAGUE)
    window_end = datetime.combine(season.ends_on, time.max, tzinfo=_PRAGUE)
    rows = await session.scalars(
        select(Event)
        .where(
            Event.workspace_id == workspace.id,
            Event.deleted_at.is_(None),
            Event.starts_at >= window_start,
            Event.starts_at <= window_end,
        )
        .order_by(Event.starts_at.asc())
    )
    return SeasonBookedResponse(items=[SeasonBookedItem.model_validate(e) for e in rows.all()])


@router.get("/calendar", response_model=CalendarView)
async def shared_calendar(
    settings: SettingsDep,
    user: SeasonReader,
    range_start: Annotated[date | None, Query(alias="from")] = None,
    range_end: Annotated[date | None, Query(alias="to")] = None,
    refresh: bool = False,
) -> CalendarView:
    """The shared household calendar, classified into blocked days + conflicts.

    One canonical answer for three consumers: the planner SPA paints the days,
    `/kulturni-prehled` and `/kulturni-sezona` save the response verbatim as
    their `blocked.json` (`blocked_days` + `conflicts` are exactly the keys
    `kp_validate.py` reads), and nobody re-implements the classification.

    Defaults to the next 180 days — the digest horizon. Never 503s: an
    unconfigured or unreachable feed answers `available: false` so a planner
    without a calendar still renders.

    `refresh=true` skips the feed cache — the planner's manual refresh, for
    "I just added the trip to the calendar" moments that would otherwise wait
    out the TTL. A forced refetch that fails still serves the cached copy.
    """

    _ = user
    start, end = _calendar_window(range_start, range_end)
    return await fetch_calendar_view(
        settings.calendar_ics_url,
        start,
        end,
        ttl_seconds=0 if refresh else settings.calendar_cache_ttl_seconds,
    )


@router.get("/holidays", response_model=HolidayView)
async def public_holidays(
    settings: SettingsDep,
    user: SeasonReader,
    range_start: Annotated[date | None, Query(alias="from")] = None,
    range_end: Annotated[date | None, Query(alias="to")] = None,
) -> HolidayView:
    """Czech public holidays over the window — a mark in the planner grid.

    Separate from `/calendar` on purpose: the holiday feed is public and the
    household feed is a secret, and one being unreachable must not blank the
    other. Holidays never block a day.
    """

    _ = user
    start, end = _calendar_window(range_start, range_end)
    return await fetch_holidays(settings.holidays_ics_url, start, end)


@router.patch("/candidates/{candidate_id}", response_model=CandidateResponse)
async def patch_candidate(
    candidate_id: UUID,
    body: CandidatePatch,
    session: SessionDep,
    user: SeasonWriter,
) -> CandidateResponse:
    workspace = await _user_workspace(session, user)
    candidate = await session.scalar(
        select(SeasonCandidate).where(
            SeasonCandidate.id == candidate_id,
            SeasonCandidate.workspace_id == workspace.id,
            SeasonCandidate.deleted_at.is_(None),
        )
    )
    if candidate is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "candidate not found")
    if candidate.version != body.version:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            {"code": "version_mismatch", "current_version": candidate.version},
        )

    if body.plan_status is not None and body.plan_status != candidate.plan_status:
        candidate.plan_status = body.plan_status
        candidate.plan_status_at = _utcnow()
    if "note" in body.model_fields_set:
        candidate.note = body.note
    candidate.version += 1
    await session.commit()
    await session.refresh(candidate)
    return CandidateResponse.model_validate(candidate)


@router.post("/scenarios/{scenario_id}/apply", response_model=PlanSummaryResponse)
async def apply_scenario(
    scenario_id: UUID,
    body: ScenarioApplyRequest,
    session: SessionDep,
    user: SeasonWriter,
) -> PlanSummaryResponse:
    workspace = await _user_workspace(session, user)
    scenario = await session.scalar(
        select(SeasonScenario).where(
            SeasonScenario.id == scenario_id,
            SeasonScenario.workspace_id == workspace.id,
            SeasonScenario.deleted_at.is_(None),
        )
    )
    if scenario is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "scenario not found")
    season = await _get_active_season(session, workspace, scenario.season_id)

    member_ids = {UUID(cid) for cid in scenario.candidate_ids}
    rows = await session.scalars(
        select(SeasonCandidate).where(
            SeasonCandidate.season_id == season.id,
            SeasonCandidate.deleted_at.is_(None),
        )
    )
    now = _utcnow()
    for candidate in rows.all():
        if candidate.id in member_ids:
            # Explicit apply wins even over an earlier manual rejection.
            if candidate.plan_status != PlanStatus.SELECTED:
                candidate.plan_status = PlanStatus.SELECTED
                candidate.plan_status_at = now
                candidate.version += 1
        elif body.mode == "replace" and candidate.plan_status == PlanStatus.SELECTED:
            candidate.plan_status = PlanStatus.UNDECIDED
            candidate.plan_status_at = now
            candidate.version += 1
        # Soft-deleted members simply never show up in `rows` — skipped.

    scenario.applied_at = now
    scenario.version += 1
    await session.commit()
    return await _plan_summary(session, season)


@router.get("/plans/{season_id}/novelties", response_model=NoveltiesResponse)
async def list_novelties(
    season_id: UUID,
    session: SessionDep,
    user: SeasonReader,
    since: Annotated[datetime | None, Query()] = None,
) -> NoveltiesResponse:
    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)

    if since is None:
        if season.novelty_ack_at is not None:
            since = season.novelty_ack_at
        else:
            # A season with no ack yet treats its own start as day zero; the
            # orchestrator acks right after the initial push so the first
            # weekly run never re-announces the whole pool.
            since = datetime.combine(season.starts_on, datetime.min.time(), tzinfo=_PRAGUE)

    rows = await session.scalars(
        select(SeasonCandidate)
        .where(
            SeasonCandidate.season_id == season.id,
            SeasonCandidate.deleted_at.is_(None),
            SeasonCandidate.first_seen_at > since,
        )
        .order_by(SeasonCandidate.first_seen_at.asc())
    )
    return NoveltiesResponse(
        items=[CandidateResponse.model_validate(c) for c in rows.all()],
        since_used=since,
        now=_utcnow(),
    )


@router.post(
    "/plans/{season_id}/novelties/ack",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
)
async def ack_novelties(
    season_id: UUID,
    body: NoveltyAckRequest,
    session: SessionDep,
    user: SeasonWriter,
) -> Response:
    workspace = await _user_workspace(session, user)
    season = await _get_active_season(session, workspace, season_id)
    # Monotonic: a stale or replayed ack can never rewind the cursor and
    # resurface novelties that were already emailed.
    if season.novelty_ack_at is None or body.through > season.novelty_ack_at:
        season.novelty_ack_at = body.through
        season.version += 1
        await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
