"""Shared household calendar (Kocourek&Prdelčička) → blocked days + conflicts.

This module is the **single canonical implementation** of the calendar
classification the whole suite depends on. It used to live in two places —
the skills read the calendar over the workspace MCP on a workstation, the
claudebox routine re-parsed the same iCal feed by hand — which meant three
consumers (weekly digest, season planner, SPA) could disagree about which
days are blocked. Now the API owns the feed and everyone reads
`GET /v1/season/calendar`.

Classification canon (unchanged from the skills):

* all-day events → every covered date is blocked (DTEND is exclusive);
* events whose summary matches the vacation regex → likewise blocked, over
  every day they span;
* every other timed event → a `conflict` window the validator compares a
  candidate's start time against (`[start-2h, end+1h]`).

The feed is a *secret* iCal address: it is read from the environment, never
logged, never echoed back in a response.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from datetime import date, datetime, timedelta
from datetime import time as clock
from zoneinfo import ZoneInfo

import httpx
import recurring_ical_events
from icalendar import Calendar, Component
from pydantic import BaseModel

logger = logging.getLogger(__name__)

PRAGUE = ZoneInfo("Europe/Prague")

_REQUEST_TIMEOUT = httpx.Timeout(10.0)
_USER_AGENT = "kp-api/1.0 +https://kulturniprehled.example.com"
# Google regenerates the feed lazily anyway; a quarter hour keeps the planner
# fresh enough for "I just added a trip to the cottage" without hammering it.
_CACHE_TTL_SECONDS = 900
# A runaway guard on the feed size (a household calendar is tens of KB).
_MAX_FEED_BYTES = 8 * 1024 * 1024

VACATION_RE = re.compile(
    r"(dovolen|holiday|pryč|pryc|away|cottage|šumperák|sumperak|chalup)",
    re.IGNORECASE,
)


class CalendarEntry(BaseModel):
    """One local day occupied by one calendar event.

    A multi-day event yields one entry per covered day, so a calendar grid can
    render it in every cell it touches without re-deriving the span.
    """

    uid: str
    title: str
    day: date
    all_day: bool
    starts_at: datetime | None
    ends_at: datetime | None
    blocking: bool
    span_days: int
    span_index: int


class CalendarConflict(BaseModel):
    """A timed window a planned event must not collide with.

    Field names are the `blocked.json` contract `kp_validate.py` reads.
    """

    start_iso: str
    end_iso: str
    title: str


class CalendarView(BaseModel):
    available: bool
    # `not_configured` (no feed URL) or `fetch_failed` — never the URL itself.
    unavailable_reason: str | None = None
    calendar_name: str | None = None
    fetched_at: datetime | None = None
    range_start: date
    range_end: date
    blocked_days: list[date]
    conflicts: list[CalendarConflict]
    entries: list[CalendarEntry]


class _CachedFeed(BaseModel):
    fetched_at: datetime
    ics: str


_cache: dict[str, tuple[float, _CachedFeed]] = {}


def reset_cache() -> None:
    """Drop the in-process feed cache (used by tests)."""

    _cache.clear()


def _empty(range_start: date, range_end: date, reason: str) -> CalendarView:
    return CalendarView(
        available=False,
        unavailable_reason=reason,
        range_start=range_start,
        range_end=range_end,
        blocked_days=[],
        conflicts=[],
        entries=[],
    )


async def _fetch_ics(url: str, client: httpx.AsyncClient) -> str:
    response = await client.get(
        url,
        headers={"User-Agent": _USER_AGENT},
        timeout=_REQUEST_TIMEOUT,
        follow_redirects=True,
    )
    response.raise_for_status()
    if len(response.content) > _MAX_FEED_BYTES:
        raise ValueError("calendar feed too large")
    return response.text


def _text(component: Component, key: str) -> str:
    raw = component.get(key)
    if raw is None:
        return ""
    return str(raw).strip()


def _as_local(moment: datetime) -> datetime:
    """Anchor a naive DTSTART to Prague; convert an aware one."""

    if moment.tzinfo is None:
        return moment.replace(tzinfo=PRAGUE)
    return moment.astimezone(PRAGUE)


def _covered_days(start: date, end: date) -> list[date]:
    """Local days an event covers, `end` exclusive, always at least one."""

    if end <= start:
        return [start]
    return [start + timedelta(days=offset) for offset in range((end - start).days)]


def _classify(
    component: Component,
    range_start: date,
    range_end: date,
) -> tuple[list[CalendarEntry], CalendarConflict | None]:
    """Turn one expanded occurrence into its per-day entries and conflict."""

    if _text(component, "STATUS").upper() == "CANCELLED":
        return [], None

    start_prop = component.get("DTSTART")
    if start_prop is None:
        return [], None
    raw_start = start_prop.dt
    end_prop = component.get("DTEND")
    raw_end = end_prop.dt if end_prop is not None else None

    title = _text(component, "SUMMARY") or "(bez názvu)"
    uid = _text(component, "UID") or title

    all_day = isinstance(raw_start, date) and not isinstance(raw_start, datetime)
    if all_day:
        start_day: date = raw_start
        end_day: date = raw_end if isinstance(raw_end, date) else start_day + timedelta(days=1)
        days = _covered_days(start_day, end_day)
        starts_at: datetime | None = None
        ends_at: datetime | None = None
    else:
        local_start = _as_local(raw_start)
        local_end = (
            _as_local(raw_end)
            if isinstance(raw_end, datetime)
            else local_start + timedelta(hours=1)
        )
        starts_at = local_start
        ends_at = local_end
        # A window ending exactly at midnight belongs to the previous day.
        exclusive_end = local_end.date()
        if local_end.time() != clock(0, 0):
            exclusive_end = exclusive_end + timedelta(days=1)
        days = _covered_days(local_start.date(), exclusive_end)

    # Canon: all-day spans block outright; a timed event blocks only when its
    # title says the household is away (a concert that runs past midnight is a
    # conflict window, not two lost days).
    blocking = all_day or VACATION_RE.search(title) is not None

    entries = [
        CalendarEntry(
            uid=uid,
            title=title,
            day=day,
            all_day=all_day,
            starts_at=starts_at,
            ends_at=ends_at,
            blocking=blocking,
            span_days=len(days),
            span_index=index,
        )
        for index, day in enumerate(days)
        if range_start <= day <= range_end
    ]

    conflict = (
        CalendarConflict(
            start_iso=starts_at.isoformat(),
            end_iso=ends_at.isoformat(),
            title=title,
        )
        if not blocking and starts_at is not None and ends_at is not None
        else None
    )
    return entries, conflict


def parse_calendar(
    ics: str,
    range_start: date,
    range_end: date,
    *,
    fetched_at: datetime | None = None,
) -> CalendarView:
    """Expand an iCal feed over `[range_start, range_end]` (inclusive days).

    Recurrence (RRULE/RDATE/EXDATE and RECURRENCE-ID overrides) is expanded by
    `recurring_ical_events` — hand-rolled VEVENT scanning silently dropped
    every repeating dinner and every moved occurrence.
    """

    calendar = Calendar.from_ical(ics)
    window_start = datetime.combine(range_start, clock(0, 0), tzinfo=PRAGUE)
    window_end = datetime.combine(range_end + timedelta(days=1), clock(0, 0), tzinfo=PRAGUE)
    occurrences = recurring_ical_events.of(calendar, skip_bad_series=True).between(
        window_start, window_end
    )

    entries: list[CalendarEntry] = []
    conflicts: list[CalendarConflict] = []
    blocked: set[date] = set()
    for occurrence in occurrences:
        occurrence_entries, conflict = _classify(occurrence, range_start, range_end)
        entries.extend(occurrence_entries)
        blocked.update(entry.day for entry in occurrence_entries if entry.blocking)
        if conflict is not None:
            conflicts.append(conflict)

    entries.sort(key=lambda entry: (entry.day, not entry.all_day, entry.starts_at or datetime.min))
    conflicts.sort(key=lambda conflict: conflict.start_iso)

    return CalendarView(
        available=True,
        calendar_name=_text(calendar, "X-WR-CALNAME") or None,
        fetched_at=fetched_at,
        range_start=range_start,
        range_end=range_end,
        blocked_days=sorted(blocked),
        conflicts=conflicts,
        entries=entries,
    )


async def fetch_calendar_view(
    url: str,
    range_start: date,
    range_end: date,
    *,
    client: httpx.AsyncClient | None = None,
    ttl_seconds: float = _CACHE_TTL_SECONDS,
) -> CalendarView:
    """Return the classified calendar window, degrading gracefully.

    No URL configured → `available=False` with `not_configured`; a failed
    fetch falls back to the last cached feed however stale, and only reports
    `fetch_failed` when nothing was ever cached. The planner showing a
    day-old calendar beats it silently showing an empty one.
    """

    if not url:
        return _empty(range_start, range_end, "not_configured")

    cached = _cache.get(url)
    if cached is not None and (time.monotonic() - cached[0]) < ttl_seconds:
        feed = cached[1]
    else:
        owns_client = client is None
        http = client or httpx.AsyncClient()
        try:
            ics = await _fetch_ics(url, http)
        except Exception:
            # Deliberately no URL, no response body — the feed address is a
            # bearer secret and this log line lands in the container output.
            logger.warning("Calendar feed fetch failed", exc_info=True)
            if cached is None:
                return _empty(range_start, range_end, "fetch_failed")
            feed = cached[1]
        else:
            feed = _CachedFeed(fetched_at=datetime.now(tz=PRAGUE), ics=ics)
            _cache[url] = (time.monotonic(), feed)
        finally:
            if owns_client:
                await http.aclose()

    try:
        # Expansion is CPU-bound (a season window over a recurring feed);
        # keep it off the event loop so a slow parse can't stall the API.
        return await asyncio.to_thread(
            parse_calendar,
            feed.ics,
            range_start,
            range_end,
            fetched_at=feed.fetched_at,
        )
    except Exception:
        logger.warning("Calendar feed parse failed", exc_info=True)
        return _empty(range_start, range_end, "fetch_failed")
