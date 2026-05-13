"""Foreign-exchange rate lookup with a local cache.

Frankfurter (https://www.frankfurter.app) publishes the ECB daily mid-rates
back to 1999. We hit the historical endpoint once per (date, base, quote)
triple and stash the result in `fx_rates`. Reports thus stay reproducible
even if the upstream rotates its dataset.

The adapter is wrapped behind an `FxRateProvider` protocol so tests can
plug in a deterministic in-memory provider — production code never has to
touch the network during unit tests.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from typing import Protocol

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.domain.models import FxRate


class FxRateProvider(Protocol):
    async def rate(
        self,
        session: AsyncSession,
        on: date,
        base: str,
        quote: str,
    ) -> Decimal: ...


class FrankfurterProvider:
    """Default provider. Hits frankfurter.app on cache miss, persists."""

    def __init__(self, client: httpx.AsyncClient | None = None) -> None:
        self._client = client or httpx.AsyncClient(
            base_url="https://api.frankfurter.app",
            timeout=10.0,
        )

    async def rate(
        self,
        session: AsyncSession,
        on: date,
        base: str,
        quote: str,
    ) -> Decimal:
        base = base.upper()
        quote = quote.upper()
        if base == quote:
            return Decimal("1")

        cached = await session.scalar(
            select(FxRate).where(
                FxRate.date == on, FxRate.base == base, FxRate.quote == quote
            )
        )
        if cached is not None:
            return cached.rate

        response = await self._client.get(
            f"/{on.isoformat()}",
            params={"from": base, "to": quote},
        )
        response.raise_for_status()
        body = response.json()
        rate = Decimal(str(body["rates"][quote]))
        session.add(
            FxRate(
                date=on,
                base=base,
                quote=quote,
                rate=rate,
            )
        )
        await session.flush()
        return rate

    async def aclose(self) -> None:
        await self._client.aclose()


async def convert(
    session: AsyncSession,
    provider: FxRateProvider,
    amount_cents: int,
    currency: str,
    on: date,
    target: str = "CZK",
) -> int:
    """Convert a minor-units integer amount to `target` minor units at the
    historic rate on `on`. Quoted both ways so callers can ask for either
    base→quote or its reciprocal without doing math themselves."""

    if currency.upper() == target.upper():
        return amount_cents
    rate = await provider.rate(session, on, currency, target)
    return int((Decimal(amount_cents) * rate).to_integral_value())
