"""Discogs taste-map adapter — pagination, parsing, dedup, graceful failure."""

from __future__ import annotations

import httpx
import pytest

from kp_api.adapters import discogs
from kp_api.adapters.discogs import fetch_discogs_taste

_PAGES = {
    "1": {
        "pagination": {"page": 1, "pages": 2},
        "releases": [
            {
                "basic_information": {
                    "title": "Symphony No. 5",
                    "year": 1985,
                    "artists": [{"name": "Gustav Mahler"}, {"name": "Bach (2)"}],
                }
            },
            {
                "basic_information": {
                    "title": "The Köln Concert",
                    "year": 0,
                    "artists": [{"name": "Keith Jarrett"}],
                }
            },
        ],
    },
    "2": {
        "pagination": {"page": 2, "pages": 2},
        "releases": [
            # Exact duplicate of a page-1 release — must be de-duplicated.
            {
                "basic_information": {
                    "title": "Symphony No. 5",
                    "year": 1985,
                    "artists": [{"name": "Gustav Mahler"}, {"name": "Bach (2)"}],
                }
            },
            {
                "basic_information": {
                    "title": "Music for 18 Musicians",
                    "year": 1978,
                    "artists": [{"name": "Steve Reich"}],
                }
            },
        ],
    },
}


def _client(handler: httpx.MockTransport) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=handler)


@pytest.fixture(autouse=True)
def _clear_cache() -> None:
    discogs.reset_cache()


@pytest.mark.asyncio
async def test_fetch_paginates_and_dedups() -> None:
    seen_pages: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["Authorization"] == "Discogs token=secret"
        page = request.url.params["page"]
        seen_pages.append(page)
        return httpx.Response(200, json=_PAGES[page])

    async with _client(httpx.MockTransport(handler)) as client:
        taste = await fetch_discogs_taste("secret", "petronijus", client=client)

    assert seen_pages == ["1", "2"]
    assert taste is not None
    # 4 releases fetched, one a duplicate → 3 unique.
    assert taste.release_count == 3
    titles = {r.title for r in taste.releases}
    assert titles == {"Symphony No. 5", "The Köln Concert", "Music for 18 Musicians"}
    # "(2)" disambiguator stripped; artists flattened, sorted, unique.
    assert taste.artists == ["Bach", "Gustav Mahler", "Keith Jarrett", "Steve Reich"]
    # year 0 → None.
    koln = next(r for r in taste.releases if r.title == "The Köln Concert")
    assert koln.year is None


@pytest.mark.asyncio
async def test_missing_token_returns_none() -> None:
    taste = await fetch_discogs_taste("", "petronijus")
    assert taste is None


@pytest.mark.asyncio
async def test_transient_failure_degrades_to_none() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503)

    async with _client(httpx.MockTransport(handler)) as client:
        taste = await fetch_discogs_taste("secret", "petronijus", client=client)

    assert taste is None


@pytest.mark.asyncio
async def test_second_call_is_cached() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return httpx.Response(200, json=_PAGES[request.url.params["page"]])

    async with _client(httpx.MockTransport(handler)) as client:
        first = await fetch_discogs_taste("secret", "petronijus", client=client)
        after = calls["n"]
        second = await fetch_discogs_taste("secret", "petronijus", client=client)

    assert first is not None and second is not None
    # Second call served from cache — no further HTTP.
    assert calls["n"] == after
