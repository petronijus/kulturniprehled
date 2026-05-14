"""Costs CRUD + change_log emission + version conflict (CZK only)."""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def _future(days: int = 14) -> str:
    return _iso(datetime.now(UTC) + timedelta(days=days))


async def _create_event(client: AsyncClient, headers: dict[str, str]) -> dict[str, str]:
    response = await client.post(
        "/v1/events",
        json={"title": "Concert", "category": "concert", "starts_at": _future()},
        headers=headers,
    )
    assert response.status_code == 201
    return response.json()


@pytest.mark.asyncio
async def test_create_cost_and_list_sums_amounts(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)

    today = date.today().isoformat()
    create = await client.post(
        f"/v1/events/{event['id']}/costs",
        json={"amount_cents": 5000, "kind": "ticket", "paid_at": today},
        headers=headers,
    )
    assert create.status_code == 201, create.text
    assert create.json()["amount_cents"] == 5000

    await client.post(
        f"/v1/events/{event['id']}/costs",
        json={"amount_cents": 1000, "kind": "transport", "paid_at": today},
        headers=headers,
    )

    listing = await client.get(f"/v1/events/{event['id']}/costs", headers=headers)
    body = listing.json()
    assert len(body["items"]) == 2
    assert body["total_amount_cents"] == 6000


@pytest.mark.asyncio
async def test_patch_requires_matching_version(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)
    created = (
        await client.post(
            f"/v1/events/{event['id']}/costs",
            json={
                "amount_cents": 1000,
                "kind": "ticket",
                "paid_at": date.today().isoformat(),
            },
            headers=headers,
        )
    ).json()

    stale = await client.patch(
        f"/v1/costs/{created['id']}",
        json={"version": 999, "amount_cents": 2000},
        headers=headers,
    )
    assert stale.status_code == 409

    fresh = await client.patch(
        f"/v1/costs/{created['id']}",
        json={"version": 1, "amount_cents": 1500, "note": "fees"},
        headers=headers,
    )
    body = fresh.json()
    assert body["version"] == 2
    assert body["amount_cents"] == 1500
    assert body["note"] == "fees"


@pytest.mark.asyncio
async def test_delete_is_soft_and_change_log_emits_delete(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)
    cost = (
        await client.post(
            f"/v1/events/{event['id']}/costs",
            json={
                "amount_cents": 100,
                "kind": "other",
                "paid_at": date.today().isoformat(),
            },
            headers=headers,
        )
    ).json()
    await client.delete(f"/v1/costs/{cost['id']}", headers=headers)

    page = (await client.get("/v1/sync", headers=headers)).json()
    cost_entries = [c for c in page["changes"] if c["entity_type"] == "cost"]
    assert [c["op"] for c in cost_entries[-2:]] == ["upsert", "delete"]
    listing = (await client.get(f"/v1/events/{event['id']}/costs", headers=headers)).json()
    assert listing["items"] == []
    assert listing["total_amount_cents"] == 0


@pytest.mark.asyncio
async def test_cross_member_visibility(client: AsyncClient) -> None:
    petr = await login_as(client, "petr@example.com")
    event = await _create_event(client, auth_header(petr["access_token"]))
    await client.post(
        f"/v1/events/{event['id']}/costs",
        json={
            "amount_cents": 200,
            "kind": "ticket",
            "paid_at": date.today().isoformat(),
        },
        headers=auth_header(petr["access_token"]),
    )
    bela = await login_as(client, "bela@example.com")
    listing = await client.get(
        f"/v1/events/{event['id']}/costs",
        headers=auth_header(bela["access_token"]),
    )
    assert listing.status_code == 200
    assert len(listing.json()["items"]) == 1
