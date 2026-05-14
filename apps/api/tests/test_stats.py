"""Stats endpoint — CZK-only aggregation."""

from __future__ import annotations

from datetime import UTC, date, datetime

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


@pytest.mark.asyncio
async def test_stats_aggregates_events_and_costs(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])

    year = 2026

    async def _event(category: str, month: int) -> dict[str, str]:
        return (
            await client.post(
                "/v1/events",
                json={
                    "title": f"{category} {month}",
                    "category": category,
                    "starts_at": _iso(
                        datetime(year, month, 15, 20, 0, tzinfo=UTC),
                    ),
                },
                headers=headers,
            )
        ).json()

    concert = await _event("concert", 1)
    await _event("concert", 2)
    theatre = await _event("theatre", 3)

    await client.patch(
        f"/v1/events/{concert['id']}",
        json={"version": 1, "status": "attended"},
        headers=headers,
    )

    await client.post(
        f"/v1/events/{concert['id']}/costs",
        json={
            "amount_cents": 1000,
            "kind": "ticket",
            "paid_at": date(year, 1, 15).isoformat(),
        },
        headers=headers,
    )
    await client.post(
        f"/v1/events/{theatre['id']}/costs",
        json={
            "amount_cents": 12000,
            "kind": "ticket",
            "paid_at": date(year, 3, 5).isoformat(),
        },
        headers=headers,
    )

    response = await client.get(f"/v1/stats?year={year}", headers=headers)
    assert response.status_code == 200, response.text
    body = response.json()

    assert body["year"] == year
    assert body["total_events"] == 3
    assert body["attended"] == 1
    assert body["upcoming"] == 2

    by_category = {row["category"]: row["count"] for row in body["by_category"]}
    assert by_category == {"concert": 2, "theatre": 1}

    months = {row["month"]: row for row in body["by_month"]}
    assert months[1]["events"] == 1
    assert months[1]["total_cost_cents"] == 1000
    assert months[3]["total_cost_cents"] == 12000

    assert body["total_cost_cents"] == 13000


@pytest.mark.asyncio
async def test_stats_for_empty_year_returns_zeros(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    response = await client.get("/v1/stats?year=2099", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["total_events"] == 0
    assert body["total_cost_cents"] == 0
    assert body["by_category"] == []
    assert body["by_month"] == []
