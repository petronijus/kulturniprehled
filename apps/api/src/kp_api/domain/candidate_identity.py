"""Identity of a pool candidate that survives a slug rewrite.

A candidate's `dedup_key` hashes its canonical URL (see
`skills/kulturni-sezona/SKILL.md`), which makes identity stable across
re-scrapes right up until the venue rewrites its slugs. On 2026-09-12
ceskafilharmonie.cz flipped every event slug from `<artist>-<series>` to
`<series>-<artist>` — the old URLs still 301 to the new ones, but the hash
of the path does not care, so 38 concerts re-entered the 2026/27 pool as
brand-new candidates next to their originals.

What survived the rewrite is the numeric id the CMS puts in front of the
slug (`/event/35524-simon-rattle-…` → `/event/35524-ceska-filharmonie-…`).
That id plus the event's local date is the secondary identity the ingest
falls back on before it creates a row: same id, same evening, same concert
— whatever the slug says this week.

Deliberately NOT covered here: the same concert published by two sources
under two unrelated URLs (a festival listing and the ensemble's own page).
That merge needs title/venue judgement, it stays with the expert skills
(`kulturni-sezona/SKILL.md`, "Cross-source merge"), and a server-side title
rule would happily collapse two genuinely different films that share a
title and a start time.
"""

from __future__ import annotations

import re
from datetime import datetime
from zoneinfo import ZoneInfo

_PRAGUE = ZoneInfo("Europe/Prague")

# `35524-simon-rattle-ceska-filharmonie` — a numeric id the CMS keeps, then
# the human-readable tail it is free to rewrite. A bare number is not enough:
# `/2026` is a year archive, not an event.
_ID_SLUG = re.compile(r"^(\d+)-.+$")
_SCHEME_AND_WWW = re.compile(r"^https?://(www\.)?", re.IGNORECASE)


def url_identity(url: str | None) -> str | None:
    """`host/path` with the id-slug tail truncated to its id, else `None`.

    `None` means "this URL carries no identity beyond its own spelling" —
    the caller then has nothing better than the `dedup_key` to go on, which
    is the status quo and correct for slug-only URLs.

    >>> url_identity("https://www.ceskafilharmonie.cz/event/35524-simon-rattle/")
    'ceskafilharmonie.cz/event/35524'
    >>> url_identity("https://www.dvorakovapraha.cz/program/concertino-praga")
    """

    if not url:
        return None
    trimmed = _SCHEME_AND_WWW.sub("", url.strip().lower())
    trimmed = trimmed.split("#")[0].split("?")[0].rstrip("/")
    if not trimmed:
        return None
    segments = trimmed.split("/")
    match = _ID_SLUG.match(segments[-1])
    if match is None:
        return None
    segments[-1] = match.group(1)
    return "/".join(segments)


def candidate_identity(url: str | None, starts_at: datetime) -> str | None:
    """Slug-proof identity of one candidate, or `None` when it has none.

    The local date is part of it: a production playing the same URL on five
    evenings is five candidates, exactly as the `dedup_key` recipe intends.
    Prague wall time decides the date — the hour of a stamp moves when a
    scraper's timezone handling is fixed, the evening it belongs to does not.
    """

    identity = url_identity(url)
    if identity is None:
        return None
    return f"{identity}|{starts_at.astimezone(_PRAGUE).date().isoformat()}"
