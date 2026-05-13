"""Stats endpoint — aggregation + multi-currency conversion."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.fx import FxRateProvider
from kp_api.api.v1 import costs as costs_module
from kp_api.api.v1 import stats as stats_module
from tests.conftest import auth_header, login_as


class _StubFx:
    def __init__(self, rates: dict[tuple[str, str], Decimal]) -> None:
        self._rates = rates

    async def rate(
        self,
        session: AsyncSession,
        on: date,
        base: str,
        quote: str,
    ) -> Decimal:
        if base == quote:
            return Decimal("1")
        return self._rates[(base, quote)]


@pytest.fixture(autouse=True)
def _stub_fx() -> None:
    stub: FxRateProvider = _StubFx(
        {
            ("EUR", "CZK"): Decimal("24"),
            ("USD", "CZK"): Decimal("22"),
        },
    )
    costs_module.set_fx_provider(stub)
    stats_module.set_fx_provider(stub)
    yield
    costs_module.set_fx_provider(None)
    stats_module.set_fx_provider(None)


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
                        datetime(year, month, 15, 20, 0, tzinfo=timezone.utc),
                    ),
                },
                headers=headers,
            )
        ).json()

    concert = await _event("concert", 1)
    await _event("concert", 2)
    theatre = await _event("theatre", 3)

    # Mark one as attended.
    await client.patch(
        f"/v1/events/{concert['id']}",
        json={"version": 1, "status": "attended"},
        headers=headers,
    )

    paid_at = date(year, 1, 15)
    await client.post(
        f"/v1/events/{concert['id']}/costs",
        json={
            "amount_cents": 1000,
            "currency": "CZK",
            "kind": "ticket",
            "paid_at": paid_at.isoformat(),
        },
        headers=headers,
    )
    await client.post(
        f"/v1/events/{theatre['id']}/costs",
        json={
            "amount_cents": 500,
            "currency": "EUR",
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
    assert months[1]["total_cost_cents"] == 1000  # CZK direct
    assert months[3]["total_cost_cents"] == 12000  # 500 EUR cents * 24

    # 1000 CZK cents + 12000 CZK cents
    assert body["total_cost_cents"] == 13000
    assert body["primary_currency"] == "CZK"


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
