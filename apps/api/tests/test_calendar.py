"""Shared-calendar ingest: iCal classification canon, caching, endpoint.

The classification is the contract three consumers share (planner SPA,
weekly digest, season planner), so the parser tests spell out each rule of
the canon rather than a happy path.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from datetime import date
from unittest.mock import patch

import httpx
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from kp_api.adapters import calendar_ics
from kp_api.adapters.calendar_ics import fetch_calendar_view, parse_calendar
from kp_api.config import Settings, get_settings
from tests.conftest import auth_header, login_as

ICS_URL = "https://calendar.google.com/calendar/ical/secret/basic.ics"


def _ics(*vevents: str) -> str:
    body = "\n".join(vevents)
    return (
        "BEGIN:VCALENDAR\r\n"
        "PRODID:-//Google Inc//Google Calendar 70.9054//EN\r\n"
        "VERSION:2.0\r\n"
        "CALSCALE:GREGORIAN\r\n"
        "X-WR-CALNAME:Kocourek&Prdelcicka\r\n"
        "X-WR-TIMEZONE:Europe/Prague\r\n"
        f"{body}\r\n"
        "END:VCALENDAR\r\n"
    )


def _vevent(uid: str, summary: str, start: str, end: str, *extra: str) -> str:
    lines = [
        "BEGIN:VEVENT",
        f"UID:{uid}",
        f"SUMMARY:{summary}",
        f"DTSTART{start}",
        f"DTEND{end}",
        *extra,
        "END:VEVENT",
    ]
    return "\r\n".join(lines)


ALL_DAY_SPAN = _vevent(
    "cottage@kp",
    "Chalupa",
    ";VALUE=DATE:20261012",
    ";VALUE=DATE:20261015",
)
TIMED_DINNER = _vevent(
    "dinner@kp",
    "Vecere u Karlovych",
    ";TZID=Europe/Prague:20261020T190000",
    ";TZID=Europe/Prague:20261020T220000",
)
WEEKLY_RUN = _vevent(
    "run@kp",
    "Ranni beh",
    ";TZID=Europe/Prague:20261005T080000",
    ";TZID=Europe/Prague:20261005T090000",
    "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=4",
)
OVERNIGHT = _vevent(
    "party@kp",
    "Party do rana",
    ";TZID=Europe/Prague:20261101T170000",
    ";TZID=Europe/Prague:20261102T010000",
)
CANCELLED = _vevent(
    "gone@kp",
    "Zrusena schuzka",
    ";TZID=Europe/Prague:20261110T100000",
    ";TZID=Europe/Prague:20261110T110000",
    "STATUS:CANCELLED",
)
TIMED_VACATION = _vevent(
    "away@kp",
    "Dovolena v Alpach",
    ";TZID=Europe/Prague:20261201T060000",
    ";TZID=Europe/Prague:20261204T220000",
)

WINDOW_START = date(2026, 10, 1)
WINDOW_END = date(2026, 12, 31)


@pytest.fixture(autouse=True)
def _clear_cache() -> None:
    calendar_ics.reset_cache()


def _days(view: calendar_ics.CalendarView, uid: str) -> list[date]:
    return [entry.day for entry in view.entries if entry.uid == uid]


def test_all_day_span_blocks_each_day_dtend_exclusive() -> None:
    view = parse_calendar(_ics(ALL_DAY_SPAN), WINDOW_START, WINDOW_END)

    assert view.calendar_name == "Kocourek&Prdelcicka"
    assert view.blocked_days == [date(2026, 10, 12), date(2026, 10, 13), date(2026, 10, 14)]
    assert view.conflicts == []
    assert [(e.span_index, e.span_days) for e in view.entries] == [(0, 3), (1, 3), (2, 3)]
    assert all(entry.all_day and entry.blocking for entry in view.entries)


def test_timed_event_becomes_a_conflict_not_a_blocked_day() -> None:
    view = parse_calendar(_ics(TIMED_DINNER), WINDOW_START, WINDOW_END)

    assert view.blocked_days == []
    assert len(view.conflicts) == 1
    conflict = view.conflicts[0]
    assert conflict.title == "Vecere u Karlovych"
    assert conflict.start_iso == "2026-10-20T19:00:00+02:00"
    assert conflict.end_iso == "2026-10-20T22:00:00+02:00"
    assert [(e.day, e.all_day, e.blocking) for e in view.entries] == [
        (date(2026, 10, 20), False, False)
    ]


def test_vacation_title_blocks_even_when_timed() -> None:
    view = parse_calendar(_ics(TIMED_VACATION), WINDOW_START, WINDOW_END)

    assert view.blocked_days == [
        date(2026, 12, 1),
        date(2026, 12, 2),
        date(2026, 12, 3),
        date(2026, 12, 4),
    ]
    # A blocked event is not also a conflict — the validator checks days first.
    assert view.conflicts == []


def test_recurrence_expands_across_the_dst_switch() -> None:
    view = parse_calendar(_ics(WEEKLY_RUN), WINDOW_START, WINDOW_END)

    assert _days(view, "run@kp") == [
        date(2026, 10, 5),
        date(2026, 10, 12),
        date(2026, 10, 19),
        date(2026, 10, 26),
    ]
    # Prague leaves DST on 2026-10-25: the last occurrence stays at 08:00 local.
    assert view.conflicts[-1].start_iso == "2026-10-26T08:00:00+01:00"


def test_overnight_event_occupies_two_days_but_blocks_neither() -> None:
    view = parse_calendar(_ics(OVERNIGHT), WINDOW_START, WINDOW_END)

    assert _days(view, "party@kp") == [date(2026, 11, 1), date(2026, 11, 2)]
    assert view.blocked_days == []
    assert view.conflicts[0].end_iso == "2026-11-02T01:00:00+01:00"


def test_cancelled_occurrence_is_ignored() -> None:
    view = parse_calendar(_ics(CANCELLED), WINDOW_START, WINDOW_END)

    assert view.entries == []
    assert view.conflicts == []


def test_window_clips_entries_to_the_requested_days() -> None:
    view = parse_calendar(_ics(ALL_DAY_SPAN), date(2026, 10, 13), date(2026, 10, 13))

    assert view.blocked_days == [date(2026, 10, 13)]
    assert [(e.span_index, e.span_days) for e in view.entries] == [(1, 3)]


async def test_missing_url_is_unavailable_not_an_error() -> None:
    view = await fetch_calendar_view("", WINDOW_START, WINDOW_END)

    assert view.available is False
    assert view.unavailable_reason == "not_configured"
    assert view.entries == []


async def test_feed_is_cached_and_a_failed_refetch_serves_the_stale_copy() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            return httpx.Response(200, text=_ics(ALL_DAY_SPAN))
        return httpx.Response(503, text="upstream down")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        first = await fetch_calendar_view(ICS_URL, WINDOW_START, WINDOW_END, client=client)
        cached = await fetch_calendar_view(ICS_URL, WINDOW_START, WINDOW_END, client=client)
        # ttl_seconds=0 forces a refetch, which fails — the stale feed stands in.
        stale = await fetch_calendar_view(
            ICS_URL, WINDOW_START, WINDOW_END, client=client, ttl_seconds=0
        )

    assert calls["n"] == 2
    assert first.available and cached.available and stale.available
    assert stale.blocked_days == first.blocked_days
    assert stale.fetched_at == first.fetched_at


async def test_first_fetch_failure_degrades_to_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="boom")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        view = await fetch_calendar_view(ICS_URL, WINDOW_START, WINDOW_END, client=client)

    assert view.available is False
    assert view.unavailable_reason == "fetch_failed"


@pytest_asyncio.fixture
async def calendar_client(settings: Settings, engine: AsyncEngine) -> AsyncIterator[AsyncClient]:
    """An app instance configured with a (stubbed) calendar feed."""

    _ = settings, engine
    with patch.dict(os.environ, {"CALENDAR_ICS_URL": ICS_URL}, clear=False):
        get_settings.cache_clear()
        from kp_api.api.v1.auth import get_verifier
        from kp_api.main import create_app
        from tests.conftest import StubVerifier

        app = create_app()
        app.dependency_overrides[get_verifier] = lambda: StubVerifier({"petr@example.com"})
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
    get_settings.cache_clear()


async def test_calendar_endpoint_serves_the_blocked_json_contract(
    calendar_client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_fetch(url: str, client: httpx.AsyncClient) -> str:
        assert url == ICS_URL
        return _ics(ALL_DAY_SPAN, TIMED_DINNER)

    monkeypatch.setattr(calendar_ics, "_fetch_ics", fake_fetch)
    pair = await login_as(calendar_client, "petr@example.com")
    headers = auth_header(pair["access_token"])

    response = await calendar_client.get(
        "/v1/season/calendar",
        params={"from": "2026-10-01", "to": "2026-12-31"},
        headers=headers,
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["available"] is True
    assert body["blocked_days"] == ["2026-10-12", "2026-10-13", "2026-10-14"]
    assert body["conflicts"] == [
        {
            "start_iso": "2026-10-20T19:00:00+02:00",
            "end_iso": "2026-10-20T22:00:00+02:00",
            "title": "Vecere u Karlovych",
        }
    ]
    assert len(body["entries"]) == 4
    # The feed address is a bearer secret — it must never travel in a response.
    assert ICS_URL not in response.text


async def test_calendar_endpoint_rejects_an_impossible_window(
    calendar_client: AsyncClient,
) -> None:
    pair = await login_as(calendar_client, "petr@example.com")
    headers = auth_header(pair["access_token"])

    backwards = await calendar_client.get(
        "/v1/season/calendar",
        params={"from": "2026-12-31", "to": "2026-10-01"},
        headers=headers,
    )
    assert backwards.status_code == 422
    assert backwards.json()["detail"]["code"] == "invalid_range"

    too_wide = await calendar_client.get(
        "/v1/season/calendar",
        params={"from": "2026-01-01", "to": "2028-01-01"},
        headers=headers,
    )
    assert too_wide.status_code == 422
    assert too_wide.json()["detail"]["code"] == "range_too_wide"


async def test_calendar_endpoint_without_a_feed_still_answers(client: AsyncClient) -> None:
    """The default test settings configure no feed — the planner must load."""

    pair = await login_as(client, "petr@example.com")
    response = await client.get("/v1/season/calendar", headers=auth_header(pair["access_token"]))

    assert response.status_code == 200
    body = response.json()
    assert body["available"] is False
    assert body["unavailable_reason"] == "not_configured"
    assert body["blocked_days"] == []
