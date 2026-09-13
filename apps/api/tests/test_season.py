"""Season-planner endpoints: lifecycle, pool ingest invariants, scenarios,
plan mutations and the novelty cursor."""

from __future__ import annotations

import hashlib
import os
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from typing import Any
from unittest.mock import patch
from uuid import UUID, uuid4

from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.config import get_settings
from kp_api.domain.models import SeasonCandidate
from tests.conftest import auth_header, login_as


def _key(seed: str) -> str:
    return hashlib.sha256(seed.encode()).hexdigest()[:64]


def _season_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "label": "2026/27",
        # A past window keeps the default novelty cursor behind every
        # first_seen_at the tests generate "now".
        "starts_on": "2025-09-01",
        "ends_on": "2026-06-30",
    }
    payload.update(overrides)
    return payload


def _candidate(seed: str, **overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "dedup_key": _key(seed),
        "lane": "klasika",
        "title": f"Concert {seed}",
        "starts_at": "2025-10-14T19:30:00+02:00",
        "venue": "Rudolfinum",
        "url": f"https://example.com/{seed}",
        "price_czk": "500-1500",
        "program": [{"composer": "Gustav Mahler", "work": "Symfonie c. 5"}],
        "score": 0.8,
        "why_cs": "Mahlera mas ve sbirce.",
        "source_type": "sezona",
        "source_name": "Ceska filharmonie",
    }
    payload.update(overrides)
    return payload


async def _auth(client: AsyncClient) -> dict[str, str]:
    pair = await login_as(client, "petr@example.com")
    return auth_header(pair["access_token"])


async def _make_season(client: AsyncClient, headers: dict[str, str], **overrides: Any) -> str:
    response = await client.post(
        "/v1/season/plans", json=_season_payload(**overrides), headers=headers
    )
    assert response.status_code == 201, response.text
    return str(response.json()["id"])


async def test_season_lifecycle(client: AsyncClient) -> None:
    headers = await _auth(client)

    missing = await client.get("/v1/season/plans/current", headers=headers)
    assert missing.status_code == 404

    season_id = await _make_season(client, headers)

    current = await client.get("/v1/season/plans/current", headers=headers)
    assert current.status_code == 200
    assert current.json()["id"] == season_id
    assert current.json()["status"] == "active"

    conflict = await client.post(
        "/v1/season/plans", json=_season_payload(label="2027/28"), headers=headers
    )
    assert conflict.status_code == 409
    assert conflict.json()["detail"]["code"] == "active_season_exists"

    handover = await client.post(
        "/v1/season/plans",
        json=_season_payload(label="2027/28", archive_current=True),
        headers=headers,
    )
    assert handover.status_code == 201, handover.text

    listing = await client.get("/v1/season/plans", headers=headers)
    assert listing.json()["total"] == 2
    statuses = {s["label"]: s["status"] for s in listing.json()["items"]}
    assert statuses == {"2026/27": "archived", "2027/28": "active"}


async def test_season_rejects_inverted_window(client: AsyncClient) -> None:
    headers = await _auth(client)
    response = await client.post(
        "/v1/season/plans",
        json=_season_payload(starts_on="2026-06-30", ends_on="2025-09-01"),
        headers=headers,
    )
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "invalid_season_window"


async def test_pool_bulk_upsert_creates(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    response = await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("a"), _candidate("b"), _candidate("c")]},
        headers=headers,
    )
    assert response.status_code == 200, response.text
    assert response.json() == {
        "created": 3,
        "updated": 0,
        "unchanged": 0,
        "total": 3,
        "vetoed": 0,
        "purged": 0,
        "rekeyed": 0,
        "merged": 0,
    }


async def test_pool_reput_is_idempotent(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    body = {"items": [_candidate("a"), _candidate("b")]}

    first = await client.put(f"/v1/season/plans/{season_id}/pool", json=body, headers=headers)
    assert first.json()["created"] == 2

    before = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    versions_before = {c["dedup_key"]: c["version"] for c in before.json()["items"]}

    second = await client.put(f"/v1/season/plans/{season_id}/pool", json=body, headers=headers)
    assert second.json() == {
        "created": 0,
        "updated": 0,
        "unchanged": 2,
        "total": 2,
        "vetoed": 0,
        "purged": 0,
        "rekeyed": 0,
        "merged": 0,
    }

    after = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    for candidate in after.json()["items"]:
        assert candidate["version"] == versions_before[candidate["dedup_key"]]
        assert candidate["last_seen_at"] >= candidate["first_seen_at"]


async def test_pool_update_refreshes_but_preserves_plan_fields(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("a")]},
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    candidate = pool.json()["items"][0]

    patched = await client.patch(
        f"/v1/season/candidates/{candidate['id']}",
        json={"version": candidate["version"], "plan_status": "selected", "note": "front row"},
        headers=headers,
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["plan_status"] == "selected"
    assert patched.json()["plan_status_at"] is not None

    refreshed = await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("a", price_czk="600-1800", tickets_available=False)]},
        headers=headers,
    )
    assert refreshed.json() == {
        "created": 0,
        "updated": 1,
        "unchanged": 0,
        "total": 1,
        "vetoed": 0,
        "purged": 0,
        "rekeyed": 0,
        "merged": 0,
    }

    after = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    row = after.json()["items"][0]
    assert row["price_czk"] == "600-1800"
    assert row["tickets_available"] is False
    assert row["plan_status"] == "selected"
    assert row["note"] == "front row"
    assert row["version"] == patched.json()["version"] + 1


async def test_pool_filters(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={
            "items": [
                _candidate("a", lane="klasika", starts_at="2025-10-01T19:00:00+02:00"),
                _candidate("b", lane="film", starts_at="2025-11-05T20:00:00+01:00"),
                _candidate("c", lane="klasika", starts_at="2025-12-20T19:30:00+01:00"),
            ]
        },
        headers=headers,
    )

    by_lane = await client.get(
        f"/v1/season/plans/{season_id}/pool", params={"lane": "film"}, headers=headers
    )
    assert by_lane.json()["total"] == 1
    assert by_lane.json()["items"][0]["lane"] == "film"

    by_window = await client.get(
        f"/v1/season/plans/{season_id}/pool",
        params={"starts_from": "2025-11-01T00:00:00Z", "starts_to": "2025-12-01T00:00:00Z"},
        headers=headers,
    )
    assert by_window.json()["total"] == 1

    by_title = await client.get(
        f"/v1/season/plans/{season_id}/pool", params={"q": "concert b"}, headers=headers
    )
    assert by_title.json()["total"] == 1

    paged = await client.get(
        f"/v1/season/plans/{season_id}/pool",
        params={"limit": 2, "offset": 2},
        headers=headers,
    )
    assert paged.json()["total"] == 3
    assert len(paged.json()["items"]) == 1


async def test_candidate_patch_version_conflict(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("a")]},
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    candidate = pool.json()["items"][0]

    stale = await client.patch(
        f"/v1/season/candidates/{candidate['id']}",
        json={"version": candidate["version"] + 5, "plan_status": "rejected"},
        headers=headers,
    )
    assert stale.status_code == 409
    assert stale.json()["detail"] == {
        "code": "version_mismatch",
        "current_version": candidate["version"],
    }


async def test_scenarios_upsert_replace_and_unknown_keys(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("a"), _candidate("b")]},
        headers=headers,
    )

    def scenario(name: str, rank: int, keys: list[str]) -> dict[str, Any]:
        return {
            "name": name,
            "description_cs": f"Motto {name}",
            "rank": rank,
            "generated_at": "2026-08-09T12:00:00+02:00",
            "candidate_keys": keys,
            "reserved_slots": [{"lane": "elektronika", "month": "2025-11", "note_cs": "klub"}],
        }

    unknown = await client.put(
        f"/v1/season/plans/{season_id}/scenarios",
        json={"scenarios": [scenario("X", 1, [_key("missing")])]},
        headers=headers,
    )
    assert unknown.status_code == 422
    assert unknown.json()["detail"]["code"] == "unknown_candidate_keys"
    assert unknown.json()["detail"]["keys"] == [_key("missing")]

    first = await client.put(
        f"/v1/season/plans/{season_id}/scenarios",
        json={
            "scenarios": [
                scenario("Velka symfonika", 1, [_key("a")]),
                scenario("Komorni sezona", 2, [_key("b")]),
            ]
        },
        headers=headers,
    )
    assert first.status_code == 200, first.text
    ids_by_name = {s["name"]: s["id"] for s in first.json()["items"]}

    second = await client.put(
        f"/v1/season/plans/{season_id}/scenarios",
        json={"scenarios": [scenario("Velka symfonika", 1, [_key("a"), _key("b")])]},
        headers=headers,
    )
    assert second.status_code == 200
    listed = await client.get(f"/v1/season/plans/{season_id}/scenarios", headers=headers)
    names = [s["name"] for s in listed.json()["items"]]
    assert names == ["Velka symfonika"]
    # Upsert by name keeps row identity across re-pushes.
    assert listed.json()["items"][0]["id"] == ids_by_name["Velka symfonika"]
    assert len(listed.json()["items"][0]["candidate_ids"]) == 2
    assert listed.json()["items"][0]["reserved_slots"][0]["month"] == "2025-11"


async def test_apply_scenario_replace_and_merge(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("a"), _candidate("b"), _candidate("c")]},
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    by_key = {c["dedup_key"]: c for c in pool.json()["items"]}

    # Pre-state: "a" manually selected (not in scenario), "b" manually
    # rejected (in scenario).
    for key, plan_status in ((_key("a"), "selected"), (_key("b"), "rejected")):
        row = by_key[key]
        response = await client.patch(
            f"/v1/season/candidates/{row['id']}",
            json={"version": row["version"], "plan_status": plan_status},
            headers=headers,
        )
        assert response.status_code == 200

    scenarios = await client.put(
        f"/v1/season/plans/{season_id}/scenarios",
        json={
            "scenarios": [
                {
                    "name": "Scenar",
                    "rank": 1,
                    "generated_at": "2026-08-09T12:00:00+02:00",
                    "candidate_keys": [_key("b"), _key("c")],
                }
            ]
        },
        headers=headers,
    )
    scenario_id = scenarios.json()["items"][0]["id"]

    applied = await client.post(
        f"/v1/season/scenarios/{scenario_id}/apply", json={"mode": "replace"}, headers=headers
    )
    assert applied.status_code == 200, applied.text
    plan = applied.json()
    selected_keys = {c["dedup_key"] for c in plan["selected"]}
    assert selected_keys == {_key("b"), _key("c")}
    assert plan["counts"] == {"selected": 2, "rejected": 0, "undecided": 1}
    assert plan["applied_scenario_id"] == scenario_id

    # Merge keeps manual selections made after the apply.
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    row_a = next(c for c in pool.json()["items"] if c["dedup_key"] == _key("a"))
    await client.patch(
        f"/v1/season/candidates/{row_a['id']}",
        json={"version": row_a["version"], "plan_status": "selected"},
        headers=headers,
    )
    merged = await client.post(
        f"/v1/season/scenarios/{scenario_id}/apply", json={"mode": "merge"}, headers=headers
    )
    merged_keys = {c["dedup_key"] for c in merged.json()["selected"]}
    assert merged_keys == {_key("a"), _key("b"), _key("c")}


async def test_plan_summary_weeks(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={
            "items": [
                # Same ISO week (2025-W42): Tue + Thu.
                _candidate("a", starts_at="2025-10-14T19:30:00+02:00"),
                _candidate("b", starts_at="2025-10-16T19:30:00+02:00"),
                # Different week.
                _candidate("c", starts_at="2025-11-20T19:30:00+01:00"),
            ]
        },
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    for candidate in pool.json()["items"]:
        await client.patch(
            f"/v1/season/candidates/{candidate['id']}",
            json={"version": candidate["version"], "plan_status": "selected"},
            headers=headers,
        )

    plan = await client.get(f"/v1/season/plans/{season_id}/plan", headers=headers)
    assert plan.status_code == 200
    weeks = {w["iso_week"]: w["count"] for w in plan.json()["weeks"]}
    assert weeks == {"2025-W42": 2, "2025-W47": 1}
    starts = [c["starts_at"] for c in plan.json()["selected"]]
    assert starts == sorted(starts)


async def test_novelties_and_monotonic_ack(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("a")]},
        headers=headers,
    )

    # Default cursor is the (past) season start — the initial pool is news.
    initial = await client.get(f"/v1/season/plans/{season_id}/novelties", headers=headers)
    assert initial.status_code == 200
    assert len(initial.json()["items"]) == 1

    cut = datetime.now(UTC).isoformat()
    ack = await client.post(
        f"/v1/season/plans/{season_id}/novelties/ack",
        json={"through": cut},
        headers=headers,
    )
    assert ack.status_code == 204

    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("fresh")]},
        headers=headers,
    )

    after = await client.get(f"/v1/season/plans/{season_id}/novelties", headers=headers)
    assert [c["dedup_key"] for c in after.json()["items"]] == [_key("fresh")]

    # A stale ack must never rewind the cursor.
    stale = await client.post(
        f"/v1/season/plans/{season_id}/novelties/ack",
        json={"through": "2020-01-01T00:00:00Z"},
        headers=headers,
    )
    assert stale.status_code == 204
    unchanged = await client.get(f"/v1/season/plans/{season_id}/novelties", headers=headers)
    assert [c["dedup_key"] for c in unchanged.json()["items"]] == [_key("fresh")]


async def test_unknown_season_returns_404(client: AsyncClient) -> None:
    headers = await _auth(client)
    response = await client.get(
        "/v1/season/plans/00000000-0000-0000-0000-000000000000/pool", headers=headers
    )
    assert response.status_code == 404


@contextmanager
def _veto(terms: str) -> Iterator[None]:
    """Turn the venue veto on for the duration of a call.

    Settings are read per request through `get_settings`, so patching the env
    (and dropping the cache) switches the veto on mid-test — which is exactly
    the real-world sequence: a pool ingested first, a veto added later.
    """

    with patch.dict(os.environ, {"SEASON_VENUE_VETO": terms}, clear=False):
        get_settings.cache_clear()
        try:
            yield
        finally:
            get_settings.cache_clear()


async def test_ingest_refuses_candidates_at_a_vetoed_venue(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    with _veto("Cross Club,Ankali,Roxy"):
        response = await client.put(
            f"/v1/season/plans/{season_id}/pool",
            json={
                "items": [
                    _candidate("keep", venue="Rudolfinum"),
                    _candidate("club", lane="elektronika", venue="Cross Club"),
                    # The veto matches the source name too — an aggregator can
                    # carry the venue there instead.
                    _candidate("agg", lane="elektronika", venue=None, source_name="Ankali"),
                    # Case and surrounding text must not matter.
                    _candidate("mixed", lane="elektronika", venue="ROXY Praha"),
                ]
            },
            headers=headers,
        )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["created"] == 1
    assert body["vetoed"] == 3
    assert body["total"] == 1

    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    assert [c["venue"] for c in pool.json()["items"]] == ["Rudolfinum"]


async def test_ingest_purges_candidates_vetoed_after_they_were_stored(
    client: AsyncClient,
) -> None:
    """The veto is retroactive — that is the whole point of the backstop."""

    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    seeded = await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={
            "items": [
                _candidate("keep", venue="Rudolfinum"),
                _candidate("club", lane="elektronika", venue="Cross Club"),
            ]
        },
        headers=headers,
    )
    assert seeded.json()["created"] == 2

    with _veto("Cross Club"):
        response = await client.put(
            f"/v1/season/plans/{season_id}/pool",
            json={"items": [_candidate("keep", venue="Rudolfinum")]},
            headers=headers,
        )
        assert response.json()["purged"] == 1

        pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
        assert [c["venue"] for c in pool.json()["items"]] == ["Rudolfinum"]


async def test_empty_ingest_purges_without_touching_anything_else(
    client: AsyncClient,
) -> None:
    """`{"items": []}` is the cleanup call — no scrape needed to apply a veto."""

    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={
            "items": [
                _candidate("keep", venue="Rudolfinum"),
                _candidate("club", lane="elektronika", venue="Cross Club"),
            ]
        },
        headers=headers,
    )

    with _veto("Cross Club"):
        response = await client.put(
            f"/v1/season/plans/{season_id}/pool", json={"items": []}, headers=headers
        )

        assert response.json() == {
            "created": 0,
            "updated": 0,
            "unchanged": 0,
            "total": 0,
            "vetoed": 0,
            "purged": 1,
            "rekeyed": 0,
            "merged": 0,
        }
        pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
        assert pool.json()["total"] == 1


def _cf(seed: str, slug: str, **overrides: Any) -> dict[str, Any]:
    """A ČF-shaped candidate: `/event/<id>-<slug>`, the id stable, the slug not."""

    url = f"https://www.ceskafilharmonie.cz/event/35524-{slug}/"
    payload = _candidate(seed, url=url, title="Ceska filharmonie - Simon Rattle")
    payload.update(overrides)
    # The real recipe: the canonical URL and the local date, never the title.
    payload["dedup_key"] = _key(f"{url}|{payload['starts_at'][:10]}")
    return payload


async def test_slug_rewrite_rekeys_the_row_instead_of_forking_a_novelty(
    client: AsyncClient,
) -> None:
    """The 2026-09-12 ČF rewrite, replayed: same concert, new slug, new key.

    Petr's decision has to come through it — a fork would have left him
    deciding the same concert twice and shown it as "new" all over again.
    """

    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_cf("old", "simon-rattle-ceska-filharmonie")]},
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    seeded = pool.json()["items"][0]
    await client.patch(
        f"/v1/season/candidates/{seeded['id']}",
        json={"version": seeded["version"], "plan_status": "selected", "note": "balkon"},
        headers=headers,
    )

    # The rewrite also fixed the venue's timezone handling, so the hour moves.
    rewritten = _cf("new", "ceska-filharmonie-simon-rattle", starts_at="2025-10-14T20:30:00+02:00")
    response = await client.put(
        f"/v1/season/plans/{season_id}/pool", json={"items": [rewritten]}, headers=headers
    )
    body = response.json()
    assert (body["created"], body["rekeyed"], body["merged"]) == (0, 1, 0)

    after = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    assert after.json()["total"] == 1
    row = after.json()["items"][0]
    assert row["id"] == seeded["id"]
    assert row["dedup_key"] == rewritten["dedup_key"]
    assert row["plan_status"] == "selected"
    assert row["note"] == "balkon"
    assert row["first_seen_at"] == seeded["first_seen_at"]
    assert datetime.fromisoformat(row["starts_at"]) == datetime(2025, 10, 14, 18, 30, tzinfo=UTC)


async def test_ingest_merges_a_fork_the_pool_already_carries(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """The state a rewrite left behind before the ingest knew how to rekey.

    Both spellings sit in the pool as two rows; the next scrape has to fold
    them back into one, carry the decision across, and take every scenario
    that pointed at the retired row with it.
    """

    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_cf("old", "simon-rattle-ceska-filharmonie"), _candidate("other")]},
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    stale = next(c for c in pool.json()["items"] if "35524" in (c["url"] or ""))
    await client.patch(
        f"/v1/season/candidates/{stale['id']}",
        json={"version": stale["version"], "plan_status": "selected", "note": "balkon"},
        headers=headers,
    )

    owner = await db_session.scalar(
        select(SeasonCandidate.created_by).where(SeasonCandidate.id == UUID(stale["id"]))
    )
    # The fork is the younger row — the rewrite happened after the original
    # had been sitting in the pool for weeks.
    forked_seen = datetime.fromisoformat(stale["first_seen_at"]) + timedelta(days=7)
    forked = _cf("new", "ceska-filharmonie-simon-rattle")
    fresh = SeasonCandidate(
        season_id=UUID(season_id),
        workspace_id=UUID(stale["workspace_id"]),
        dedup_key=forked["dedup_key"],
        content_hash="0" * 64,
        lane="klasika",
        title=forked["title"],
        starts_at=datetime(2025, 10, 14, 18, 30, tzinfo=UTC),
        url=forked["url"],
        created_by=owner,
        first_seen_at=forked_seen,
        last_seen_at=forked_seen,
    )
    db_session.add(fresh)
    await db_session.commit()

    await client.put(
        f"/v1/season/plans/{season_id}/scenarios",
        json={
            "scenarios": [
                {
                    "name": "Velka symfonika",
                    "rank": 1,
                    "generated_at": "2025-09-30T12:00:00Z",
                    "candidate_keys": [stale["dedup_key"], _key("other")],
                }
            ],
            "replace": True,
        },
        headers=headers,
    )

    response = await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [forked, _candidate("other")]},
        headers=headers,
    )
    body = response.json()
    assert (body["created"], body["merged"]) == (0, 1)

    after = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    rows = {c["dedup_key"]: c for c in after.json()["items"]}
    assert after.json()["total"] == 2
    survivor = rows[forked["dedup_key"]]
    assert survivor["id"] == str(fresh.id)
    assert survivor["plan_status"] == "selected"
    assert survivor["note"] == "balkon"
    # The retired row was in the pool first; the survivor inherits that, or it
    # reports itself as a novelty every week from here on.
    assert survivor["first_seen_at"] == stale["first_seen_at"]

    scenarios = await client.get(f"/v1/season/plans/{season_id}/scenarios", headers=headers)
    members = scenarios.json()["items"][0]["candidate_ids"]
    assert str(fresh.id) in members
    assert stale["id"] not in members
    assert len(members) == 2


async def test_one_payload_carrying_both_spellings_lands_as_one_row(
    client: AsyncClient,
) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    response = await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={
            "items": [
                _cf("old", "simon-rattle-ceska-filharmonie"),
                _cf("new", "ceska-filharmonie-simon-rattle"),
            ]
        },
        headers=headers,
    )
    assert response.json()["created"] == 1
    assert response.json()["total"] == 1

    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    assert pool.json()["total"] == 1


async def test_identity_keeps_the_nights_of_one_production_apart(
    client: AsyncClient,
) -> None:
    """Same URL, two evenings — two candidates, and no merge between them."""

    headers = await _auth(client)
    season_id = await _make_season(client, headers)

    response = await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={
            "items": [
                _cf("night-one", "rattle", starts_at="2025-10-14T19:30:00+02:00"),
                _cf("night-two", "rattle", starts_at="2025-10-15T19:30:00+02:00"),
            ]
        },
        headers=headers,
    )
    assert response.json()["created"] == 2
    assert response.json()["merged"] == 0


async def test_delete_candidate_retires_it_from_the_pool(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("gone"), _candidate("stays")]},
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    doomed = next(c for c in pool.json()["items"] if c["dedup_key"] == _key("gone"))

    stale = await client.delete(
        f"/v1/season/candidates/{doomed['id']}?version={doomed['version'] + 1}",
        headers=headers,
    )
    assert stale.status_code == 409
    assert stale.json()["detail"]["current_version"] == doomed["version"]

    response = await client.delete(
        f"/v1/season/candidates/{doomed['id']}?version={doomed['version']}", headers=headers
    )
    assert response.status_code == 204

    after = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    assert [c["dedup_key"] for c in after.json()["items"]] == [_key("stays")]

    # Gone means gone from the pool, not blacklisted: a later scrape that still
    # lists the event simply creates it again.
    again = await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={"items": [_candidate("gone")]},
        headers=headers,
    )
    assert again.json()["created"] == 1


async def test_delete_candidate_rejects_an_unknown_id(client: AsyncClient) -> None:
    headers = await _auth(client)
    response = await client.delete(
        f"/v1/season/candidates/{uuid4()}?version=1",
        headers=headers,
    )
    assert response.status_code == 404
