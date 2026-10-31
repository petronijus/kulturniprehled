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

The same guess bit the ticket ingest: the model wrote the offset of a ticket's
start time by hand, copied the summer `+02:00` of the skill's example, and
put the 2026-10-31 opera an hour early. Skills that start from a wall-clock
reading call the command line instead of writing an offset:

    python3 prague_time.py wall-clock "2026-10-31 19:00" [Europe/Prague]
    → 2026-10-31T19:00:00+01:00
"""

from __future__ import annotations

import html
import re
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

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


def wall_clock(text: str, tz_name: str = "Europe/Prague") -> str:
    """ISO stamp with the right offset for a wall-clock reading in `tz_name`.

    `text` is a local date and time without any offset ("2026-10-31 19:00" or
    "2026-10-31T19:00"); one with an offset is refused, since the point is
    that nobody writes the offset by hand. A time that does not exist on that
    day (inside the spring-forward gap) is refused rather than shifted.
    """

    try:
        naive = datetime.fromisoformat(text.strip())
    except ValueError as error:
        raise ValueError(f"not a local date and time: {text!r}") from error
    if naive.tzinfo is not None:
        raise ValueError(f"give the wall-clock time without an offset: {text!r}")
    try:
        zone = ZoneInfo(tz_name)
    except (ZoneInfoNotFoundError, ValueError) as error:
        raise ValueError(f"unknown time zone: {tz_name!r}") from error
    local = naive.replace(tzinfo=zone)
    if local.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) != naive:
        raise ValueError(f"{text!r} does not exist in {tz_name} (clocks skip it)")
    return local.isoformat()


def _main(argv: list[str]) -> int:
    if len(argv) not in (2, 3) or argv[0] != "wall-clock":
        print(
            "usage: prague_time.py wall-clock 'YYYY-MM-DD HH:MM' [IANA zone]",
            file=sys.stderr,
        )
        return 2
    try:
        print(wall_clock(*argv[1:]))
    except ValueError as error:
        print(f"prague_time: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
