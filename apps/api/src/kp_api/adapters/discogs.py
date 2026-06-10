"""Discogs collection → qualitative taste map.

Petr's vinyl collection is the *long-term* taste anchor for the klasika
lane (Spotify only carries recent listening). The cloud digest routine
used to fetch this itself with its own Discogs token; serving it from
`GET /v1/digest/context` instead means the routine holds no Discogs
secret and the cloud environment needs no `api.discogs.com` egress.

The collection changes rarely and Discogs rate-limits authenticated
callers to 60 req/min, so the fetched map is cached in-process with a
TTL. A missing token (or any transient Discogs failure) degrades
gracefully to a previously cached value, or to `None` — the expert
already treats an absent Discogs profile as non-fatal.
"""

from __future__ import annotations

import logging
import re
import time
from typing import Any

import httpx
from pydantic import BaseModel

logger = logging.getLogger(__name__)

_COLLECTION_URL = "https://api.discogs.com/users/{username}/collection/folders/0/releases"
_PER_PAGE = 100
_MAX_PAGES = 50  # 5000 releases — a runaway guard, far above any real collection.
_REQUEST_TIMEOUT = httpx.Timeout(10.0)
_USER_AGENT = "kp-api/1.0 +https://kulturniprehled.example.com"
_CACHE_TTL_SECONDS = 6 * 3600

# Discogs disambiguates same-named artists as "Bach (2)"; strip the suffix so
# the taste map keys on the plain name.
_DISAMBIG_RE = re.compile(r"\s*\(\d+\)$")


class DiscogsRelease(BaseModel):
    title: str
    artists: list[str]
    year: int | None


class DiscogsTaste(BaseModel):
    username: str
    release_count: int
    # Flat, de-duplicated, sorted — the qualitative "does composer X appear
    # in the collection at all" signal. NOT a count: presence is what matters.
    artists: list[str]
    # Per-release titles so the expert can spot a specific work match
    # (owns Mahler 5 on vinyl, concert plays Mahler 5).
    releases: list[DiscogsRelease]


_cache: dict[str, tuple[float, DiscogsTaste]] = {}


def reset_cache() -> None:
    """Drop the in-process cache (used by tests)."""

    _cache.clear()


def _clean_name(name: str) -> str:
    return _DISAMBIG_RE.sub("", name).strip()


def _parse_release(raw: Any) -> DiscogsRelease | None:
    info = raw.get("basic_information") if isinstance(raw, dict) else None
    if not isinstance(info, dict):
        return None
    title = info.get("title")
    if not isinstance(title, str) or not title.strip():
        return None
    artists = [
        _clean_name(a["name"])
        for a in info.get("artists", [])
        if isinstance(a, dict) and isinstance(a.get("name"), str) and a["name"].strip()
    ]
    year = info.get("year")
    return DiscogsRelease(
        title=title.strip(),
        artists=artists,
        # Discogs reports an unknown year as 0.
        year=year if isinstance(year, int) and year > 0 else None,
    )


async def _fetch(token: str, username: str, client: httpx.AsyncClient) -> DiscogsTaste:
    headers = {
        "Authorization": f"Discogs token={token}",
        "User-Agent": _USER_AGENT,
    }
    url = _COLLECTION_URL.format(username=username)
    releases: list[DiscogsRelease] = []
    seen: set[tuple[str, tuple[str, ...]]] = set()
    artists: set[str] = set()

    page = 1
    while page <= _MAX_PAGES:
        response = await client.get(
            url,
            params={"per_page": _PER_PAGE, "page": page},
            headers=headers,
            timeout=_REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        payload: Any = response.json()
        rows = payload.get("releases", []) if isinstance(payload, dict) else []
        for raw in rows:
            release = _parse_release(raw)
            if release is None:
                continue
            key = (release.title, tuple(release.artists))
            if key not in seen:
                seen.add(key)
                releases.append(release)
            artists.update(release.artists)

        pagination = payload.get("pagination", {}) if isinstance(payload, dict) else {}
        pages = pagination.get("pages", 1) if isinstance(pagination, dict) else 1
        if not isinstance(pages, int) or page >= pages:
            break
        page += 1

    return DiscogsTaste(
        username=username,
        release_count=len(releases),
        artists=sorted(artists),
        releases=releases,
    )


async def fetch_discogs_taste(
    token: str,
    username: str,
    *,
    client: httpx.AsyncClient | None = None,
    ttl_seconds: float = _CACHE_TTL_SECONDS,
) -> DiscogsTaste | None:
    """Return Petr's Discogs taste map, or `None` if unavailable.

    `None` (not an error) when no token/username is configured or Discogs
    is unreachable and nothing is cached — callers treat an absent profile
    as a soft-missing source.
    """

    if not token or not username:
        return None

    cached = _cache.get(username)
    if cached is not None and (time.monotonic() - cached[0]) < ttl_seconds:
        return cached[1]

    owns_client = client is None
    http = client or httpx.AsyncClient()
    try:
        taste = await _fetch(token, username, http)
    except Exception:
        logger.warning("Discogs taste fetch failed for %s", username, exc_info=True)
        return cached[1] if cached is not None else None
    finally:
        if owns_client:
            await http.aclose()

    _cache[username] = (time.monotonic(), taste)
    return taste
