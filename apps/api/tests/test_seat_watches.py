"""Seat watches: the standing instruction to look at a sold-out hall.

The runner is a single timer serving every watch, so these tests care most
about the two things that decide whether a night's sleep is interrupted
usefully: a hit ends the watch, and re-watching the same concert does not
quietly grow a second one.
"""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient

from tests.conftest import auth_header, login_as


async def _auth(client: AsyncClient) -> dict[str, str]:
    pair = await login_as(client, "petr@example.com")
    return auth_header(pair["access_token"])


HALL = "https://tickets.example.cz/standard/Hall/Index/4199984/_sla_token__"


def _watch(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "label": "Yuja Wang — 11. 12. 2026",
        "hall_url": HALL,
        "starts_at": "2030-12-11T19:30:00+01:00",
        "min_adjacent": 2,
        "exclude_categories": ["stani", "vozickari"],
    }
    payload.update(overrides)
    return payload


async def test_creating_a_watch_is_all_the_scheduling_there_is(client: AsyncClient) -> None:
    headers = await _auth(client)

    created = await client.post("/v1/season/watches", json=_watch(), headers=headers)
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["state"] == "active"
    assert body["min_adjacent"] == 2
    assert body["last_checked_at"] is None

    # The runner asks for work and finds it without anything else being set up.
    due = await client.get("/v1/season/watches?due=true", headers=headers)
    assert [w["id"] for w in due.json()["items"]] == [body["id"]]


async def test_seats_found_ends_the_watch(client: AsyncClient) -> None:
    """A hit is something to act on inside twenty minutes, not a state."""

    headers = await _auth(client)
    watch = (await client.post("/v1/season/watches", json=_watch(), headers=headers)).json()

    quiet = await client.post(
        f"/v1/season/watches/{watch['id']}/checked",
        json={"free_seats": 1},
        headers=headers,
    )
    assert quiet.json()["state"] == "active"
    assert quiet.json()["last_free_seats"] == 1

    hit = await client.post(
        f"/v1/season/watches/{watch['id']}/checked",
        json={
            "free_seats": 2,
            "found_seats": [
                {"row": "8", "seat": "14", "category": "DS-II", "price_czk": 1550},
                {"row": "8", "seat": "15", "category": "DS-II", "price_czk": 1550},
            ],
        },
        headers=headers,
    )
    assert hit.json()["state"] == "found"
    assert hit.json()["found_at"] is not None
    assert len(hit.json()["found_seats"]) == 2

    # And it stops being handed to the runner, so the same pair is never
    # announced twice.
    due = await client.get("/v1/season/watches?due=true", headers=headers)
    assert due.json()["items"] == []


async def test_watching_the_same_candidate_twice_revives_one_watch(
    client: AsyncClient,
) -> None:
    headers = await _auth(client)
    season = await client.post(
        "/v1/season/plans",
        json={"label": "2026/27", "starts_on": "2026-09-01", "ends_on": "2027-06-30"},
        headers=headers,
    )
    season_id = season.json()["id"]
    await client.put(
        f"/v1/season/plans/{season_id}/pool",
        json={
            "items": [
                {
                    "dedup_key": "f" * 64,
                    "lane": "klasika",
                    "title": "Yuja Wang",
                    "starts_at": "2030-12-11T19:30:00+01:00",
                }
            ]
        },
        headers=headers,
    )
    pool = await client.get(f"/v1/season/plans/{season_id}/pool", headers=headers)
    candidate_id = pool.json()["items"][0]["id"]

    first = (
        await client.post(
            "/v1/season/watches", json=_watch(candidate_id=candidate_id), headers=headers
        )
    ).json()
    await client.post(
        f"/v1/season/watches/{first['id']}/checked",
        json={"free_seats": 2, "found_seats": [{"row": "8", "seat": "14"}]},
        headers=headers,
    )

    again = await client.post(
        "/v1/season/watches",
        json=_watch(candidate_id=candidate_id, hall_url=HALL + "fresh"),
        headers=headers,
    )
    assert again.status_code == 201
    assert again.json()["id"] == first["id"]
    assert again.json()["state"] == "active"
    # The revived watch starts clean: last time's seats are gone.
    assert again.json()["found_seats"] is None
    assert again.json()["hall_url"].endswith("fresh")

    listed = await client.get("/v1/season/watches", headers=headers)
    assert listed.json()["total"] == 1


async def test_an_expired_link_is_reported_and_a_fresh_one_clears_it(
    client: AsyncClient,
) -> None:
    """The hall link carries its own session, so it expires. Say so."""

    headers = await _auth(client)
    watch = (await client.post("/v1/season/watches", json=_watch(), headers=headers)).json()

    failed = await client.post(
        f"/v1/season/watches/{watch['id']}/checked",
        json={"free_seats": 0, "error": "content_expired"},
        headers=headers,
    )
    assert failed.json()["last_error"] == "content_expired"
    assert failed.json()["state"] == "active"

    revived = await client.patch(
        f"/v1/season/watches/{watch['id']}",
        json={"version": failed.json()["version"], "hall_url": HALL + "new"},
        headers=headers,
    )
    assert revived.status_code == 200
    assert revived.json()["last_error"] is None


async def test_a_watch_whose_concert_has_happened_expires(client: AsyncClient) -> None:
    headers = await _auth(client)
    watch = (
        await client.post(
            "/v1/season/watches",
            json=_watch(starts_at="2020-01-01T19:30:00+01:00"),
            headers=headers,
        )
    ).json()

    checked = await client.post(
        f"/v1/season/watches/{watch['id']}/checked", json={"free_seats": 0}, headers=headers
    )
    assert checked.json()["state"] == "expired"
    due = await client.get("/v1/season/watches?due=true", headers=headers)
    assert due.json()["items"] == []


async def test_stopping_and_deleting_a_watch(client: AsyncClient) -> None:
    headers = await _auth(client)
    watch = (await client.post("/v1/season/watches", json=_watch(), headers=headers)).json()

    stopped = await client.patch(
        f"/v1/season/watches/{watch['id']}",
        json={"version": watch["version"], "state": "stopped"},
        headers=headers,
    )
    assert stopped.json()["state"] == "stopped"
    assert (await client.get("/v1/season/watches?due=true", headers=headers)).json()["items"] == []

    stale = await client.patch(
        f"/v1/season/watches/{watch['id']}",
        json={"version": watch["version"], "state": "active"},
        headers=headers,
    )
    assert stale.status_code == 409

    gone = await client.delete(f"/v1/season/watches/{watch['id']}", headers=headers)
    assert gone.status_code == 204
    assert (await client.get("/v1/season/watches", headers=headers)).json()["total"] == 0
