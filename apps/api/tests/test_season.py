"""Season-planner endpoints: lifecycle, pool ingest invariants, scenarios,
plan mutations and the novelty cursor."""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from typing import Any

from httpx import AsyncClient

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
    assert response.json() == {"created": 3, "updated": 0, "unchanged": 0, "total": 3}


async def test_pool_reput_is_idempotent(client: AsyncClient) -> None:
    headers = await _auth(client)
    season_id = await _make_season(client, headers)
    body = {"items": [_candidate("a"), _candidate("b")]}

    first = await client.put(f"/v1/season/plans/{season_id}/pool", json=body, headers=headers)
    assert first.json()["created"] == 2

    before = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    versions_before = {c["dedup_key"]: c["version"] for c in before.json()["items"]}

    second = await client.put(f"/v1/season/plans/{season_id}/pool", json=body, headers=headers)
    assert second.json() == {"created": 0, "updated": 0, "unchanged": 2, "total": 2}

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
    assert refreshed.json() == {"created": 0, "updated": 1, "unchanged": 0, "total": 1}

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
