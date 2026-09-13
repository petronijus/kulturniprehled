#!/usr/bin/env python3
"""Check every open seat watch once, and say so when seats turn up.

A sold-out concert leaks seats back one cancellation at a time. The watches
live in the KP API; this walks the due ones, reads each hall, and reports the
result back. One timer serves every watch, so adding a watch in the planner is
the whole of scheduling it — there is no per-concert cron to write.

Why no browser: the ticketing link carries its own authorization in the path,
so a plain GET gets through the waiting room and reaches the seat map. That
also means the link expires; a check that lands on `ContentExpired` reports
`content_expired` and the planner asks for a fresh one instead of the watch
dying quietly.

Reading only. Nothing here puts a seat in a basket — the notification carries
the link and the twenty-minute hold is Petr's to start.

    KP_API_BASE=…  KP_TOKEN=…  seat-watch.py [--once] [--verbose]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import smtplib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from email.message import EmailMessage
from typing import Any

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
KP_UA = "kp-seat-watch/1.0"
# Seats are absolutely positioned; neighbours share a row and sit one pitch
# apart. Real halls measure 18–19px at the default zoom, so the window is
# wide enough for a rounding difference and far short of the next block.
PITCH_MIN, PITCH_MAX = 12, 26
ROW_TOLERANCE = 3
# Politeness: this is someone else's box office.
PER_WATCH_PAUSE = 2.0


class HallUnavailable(Exception):
    """The hall could not be read — the reason is the message."""


def kp(method: str, path: str, body: dict[str, Any] | None = None) -> Any:
    base, token = os.environ["KP_API_BASE"], os.environ["KP_TOKEN"]
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    request = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": KP_UA,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


def _get(url: str, jar: dict[str, str], referer: str | None = None) -> tuple[str, str]:
    """GET with a hand-rolled cookie jar; returns (body, final url)."""

    headers = {"User-Agent": UA}
    if jar:
        headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in jar.items())
    if referer:
        headers["Referer"] = referer
        headers["X-Requested-With"] = "XMLHttpRequest"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, headers=headers), timeout=45
        ) as response:
            for raw in response.headers.get_all("Set-Cookie") or []:
                name, _, rest = raw.partition("=")
                jar[name.strip()] = rest.split(";")[0]
            return response.read().decode("utf-8", "replace"), response.geturl()
    except urllib.error.HTTPError as error:
        raise HallUnavailable(f"http_{error.code}") from error
    except Exception as error:  # noqa: BLE001 - any transport failure is one outcome
        raise HallUnavailable(f"fetch_failed: {type(error).__name__}") from error


def read_hall(hall_url: str) -> list[dict[str, Any]]:
    """Walk the waiting room to the seat map and parse it.

    Three steps, exactly what the browser does: the link lands on a waiting
    page, an XHR asks where the hall is, and the hall's own XHR fetches the
    seats.
    """

    jar: dict[str, str] = {}
    page, final = _get(hall_url, jar)
    if "ContentExpired" in final or "ContentExpired" in page:
        raise HallUnavailable("content_expired")

    origin = "{0.scheme}://{0.netloc}".format(urllib.parse.urlsplit(final))
    prepare = re.search(r'id="ajaxPathToPrepareData"[^>]*value="([^"]+)"', page)
    if prepare is not None:
        target, _ = _get(origin + prepare.group(1), jar, referer=final)
        target = target.strip().strip('"')
        if not target.startswith("/"):
            raise HallUnavailable(f"prepare_said: {target[:60]}")
        page, final = _get(origin + target, jar)

    event = re.search(r'id="HallEventId"[^>]*value="(\d+)"', page)
    seats_path = re.search(r'id="hallAjaxSeatsPath"[^>]*value="([^"]+)"', page)
    section = re.search(r'id="HallSectionId"[^>]*value="(-?\d+)"', page)
    currency = re.search(r'id="HallCurrencyId"[^>]*value="(\d+)"', page)
    if not (event and seats_path):
        raise HallUnavailable("no_hall_on_page")

    query = urllib.parse.urlencode(
        {
            "eventid": event.group(1),
            "sectionid": section.group(1) if section else "-2147483648",
            "currencyid": currency.group(1) if currency else "1",
            "x": 0,
            "y": 0,
            "containerWidth": 1100,
            "ignoreMe": int(time.time() * 1000),
        }
    )
    payload, _ = _get(f"{origin}{seats_path.group(1)}?{query}", jar, referer=final)

    seats: list[dict[str, Any]] = []
    for match in re.finditer(
        r"<div style='left:(\d+)px;top:(\d+)px;[^']*'\s+class='([^']*is_seat[^']*)'([^>]*)>",
        payload,
    ):
        left, top, classes, rest = match.groups()
        category = re.search(r"ckt_(\d+)", classes)
        seats.append(
            {
                "left": int(left),
                "top": int(top),
                "occupied": "occupied" in classes,
                "category": category.group(1) if category else None,
                "seat_id": (re.search(r"id='([^']+)'", rest) or [None, None])[1],
            }
        )
    if not seats:
        raise HallUnavailable("no_seats_parsed")
    return seats


def find_adjacent(
    seats: list[dict[str, Any]], want: int, exclude: list[str] | None
) -> list[dict[str, Any]]:
    """The first run of `want` free seats side by side in one row.

    Rows come from the y coordinate — the map has no row markup — so seats
    within a few pixels of each other count as the same row.
    """

    blocked = set(exclude or [])
    free = [s for s in seats if not s["occupied"] and s["category"] not in blocked]
    rows: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for seat in free:
        anchor = next(
            (r for r in rows if abs(r - seat["top"]) <= ROW_TOLERANCE),
            seat["top"],
        )
        rows[anchor].append(seat)

    for _, row in sorted(rows.items()):
        row.sort(key=lambda s: s["left"])
        run = [row[0]]
        for previous, seat in zip(row, row[1:], strict=False):
            if PITCH_MIN <= seat["left"] - previous["left"] <= PITCH_MAX:
                run.append(seat)
            else:
                run = [seat]
            if len(run) >= want:
                return run[:want]
    return []


def notify(watch: dict[str, Any], found: list[dict[str, Any]]) -> bool:
    """Mail the hit. Returns whether it went out.

    The message is short on purpose: it is read on a phone, and the only
    thing to do with it is open the link before the seats go again.
    """

    host = os.environ.get("SMTP_HOST")
    to = os.environ.get("SEAT_WATCH_MAIL_TO") or os.environ.get("DIGEST_MAIL_TO")
    if not (host and to):
        return False
    where = ", ".join(
        f"{s['category'] or '?'} @ {s['left']}×{s['top']}" for s in found
    )
    message = EmailMessage()
    message["Subject"] = f"🎟 Uvolnila se místa: {watch['label']}"
    message["From"] = os.environ.get("DIGEST_MAIL_FROM", to)
    message["To"] = to
    message.set_content(
        f"{watch['label']}\n\n"
        f"Volno: {len(found)} míst vedle sebe ({where}).\n\n"
        f"Klikni a dej je do košíku — pak jsou 20 minut tvoje:\n{watch['hall_url']}\n\n"
        "Hlídač po tomhle nálezu končí. Když je nestihneš, založ ho v planneru znovu.\n"
    )
    port = int(os.environ.get("SMTP_PORT", "587"))
    with smtplib.SMTP(host, port, timeout=30) as smtp:
        if os.environ.get("SMTP_STARTTLS", "1") == "1":
            smtp.starttls()
        user, password = os.environ.get("SMTP_USER"), os.environ.get("SMTP_PASSWORD")
        if user and password:
            smtp.login(user, password)
        smtp.send_message(message)
    return True


def run_once(verbose: bool) -> int:
    watches = kp("GET", "/v1/season/watches?due=true")["items"]
    if verbose:
        print(f"{len(watches)} watch(es) due", file=sys.stderr)
    hits = 0
    for index, watch in enumerate(watches):
        if index:
            time.sleep(PER_WATCH_PAUSE)
        try:
            seats = read_hall(watch["hall_url"])
        except HallUnavailable as error:
            kp(
                "POST",
                f"/v1/season/watches/{watch['id']}/checked",
                {"free_seats": 0, "error": str(error)},
            )
            print(f"{watch['label']}: {error}", file=sys.stderr)
            continue

        free = [s for s in seats if not s["occupied"]]
        found = find_adjacent(seats, watch["min_adjacent"], watch["exclude_categories"])
        result: dict[str, Any] = {"free_seats": len(free)}
        if found:
            result["found_seats"] = found
        kp("POST", f"/v1/season/watches/{watch['id']}/checked", result)

        if found:
            hits += 1
            sent = notify(watch, found)
            print(
                f"{watch['label']}: {len(found)} seats together"
                f"{'' if sent else ' (no mail configured)'}",
                file=sys.stderr,
            )
        elif verbose:
            print(f"{watch['label']}: {len(free)} free, none together", file=sys.stderr)
    return hits


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true", help="kept for symmetry; always one pass")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    for name in ("KP_API_BASE", "KP_TOKEN"):
        if not os.environ.get(name):
            print(f"{name} is not set", file=sys.stderr)
            return 2
    try:
        run_once(args.verbose)
    except Exception as error:  # noqa: BLE001 - a timer wants a clean exit code
        print(f"seat-watch failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
