"""One place where a Prague concert's wall-clock time becomes a real instant.

Every ensemble scraper used to close its stamp with a hard-coded `+02:00`,
which is right from late March to late October and an hour early for the
rest of the season — the half the season actually lives in. The pool carried
that error on every winter concert until 2026-09.

Venue stamps come in three flavours and each needs its own call:

* nothing at all — a date and a time parsed out of the page's text
  (`prague_parts`),
* a real ISO stamp with a real offset (`stamp`, which honours it),
* an ISO stamp ending in `Z` that is not UTC at all — fok.cz prints
  `2026-09-26T20:15:00Z` next to "20:15" in its own listing (`stamp` with
  `trust_offset=False`, which throws the lie away and reads the wall clock).

Emitted stamps always carry an explicit offset, so whoever parses them next
cannot repeat the guess.
"""

from __future__ import annotations

import html
import re
from datetime import datetime
from zoneinfo import ZoneInfo

PRAGUE = ZoneInfo("Europe/Prague")

# Umbraco writes seven fractional digits ("2026-05-25T15:30:00.0000000"),
# more than `fromisoformat` took before 3.11 and more than anyone needs.
_FRACTION = re.compile(r"\.\d+")


def prague_parts(year: int, month: int, day: int, hour: int, minute: int) -> str:
    """ISO stamp for a Prague wall-clock reading. DST is resolved for you."""

    return datetime(year, month, day, hour, minute, tzinfo=PRAGUE).isoformat()


def stamp(raw: str, *, trust_offset: bool = True) -> str | None:
    """Normalize one `<time datetime>` value, or `None` if it is unreadable.

    HTML entities are unescaped first: ceskafilharmonie.cz serves its offset
    as `&#x2B;02:00`, and a `+` left as an entity turns the whole stamp into
    garbage that no parser accepts.
    """

    text = _FRACTION.sub("", html.unescape(raw).strip(), count=1)
    if not trust_offset:
        text = re.sub(r"(Z|[+-]\d{2}:?\d{2})$", "", text)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=PRAGUE)
    return parsed.isoformat()
