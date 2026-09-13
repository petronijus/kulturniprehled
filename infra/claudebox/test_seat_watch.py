#!/usr/bin/env python3
"""Tests for the seat watcher's two hard parts: parsing a hall and deciding
what counts as "seats together".

Stdlib only and runnable on its own (`python3 test_seat_watch.py`), the same
deal as `kulturni-sezona/bin/test_kp_validate.py` — the claudebox has no
pytest and this has to be checkable there.

The fixture is shaped like the real thing: seats are absolutely positioned
divs, the row lives in the y coordinate and nowhere else, and the pitch is
the 17-19px the Rudolfinum map actually uses.
"""

from __future__ import annotations

import importlib.util
import pathlib
import re
import sys

spec = importlib.util.spec_from_file_location("seat_watch", pathlib.Path(__file__).with_name("seat-watch.py"))
assert spec is not None and spec.loader is not None
seat_watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seat_watch)

PITCH = 18
STANDING = "7328"
SEATED = "7323"


def hall(rows: list[list[bool]], category: str = SEATED) -> list[dict[str, object]]:
    """`rows[r][s] is True` → that seat is free."""

    seats = []
    for r, row in enumerate(rows):
        for s, free in enumerate(row):
            seats.append(
                {
                    "left": 100 + s * PITCH,
                    "top": 200 + r * 30,
                    "occupied": not free,
                    "category": category,
                    "seat_id": f"s_{r}_{s}",
                }
            )
    return seats


def check(name: str, got: object, want: object) -> bool:
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f"\n       got {got!r}\n      want {want!r}"))
    return ok


def positions(found: list[dict[str, object]]) -> list[tuple[int, int]]:
    return [(s["left"], s["top"]) for s in found]  # type: ignore[misc]


def main() -> int:
    results = []

    # --- what a hit is -----------------------------------------------------
    seats = hall([[False] * 10, [False, False, True, True, False, False]])
    results.append(
        check(
            "two free neighbours are a pair",
            positions(seat_watch.find_adjacent(seats, 2, None)),
            [(100 + 2 * PITCH, 230), (100 + 3 * PITCH, 230)],
        )
    )

    # A single seat is the usual case when something frees up, and it is not
    # what Petr asked for — two people cannot sit in it.
    seats = hall([[False, False, True, False, False, False]])
    results.append(check("a lone seat is not a pair", seat_watch.find_adjacent(seats, 2, None), []))

    # Two free seats with an occupied one between them are not together.
    seats = hall([[False, True, False, True, False]])
    results.append(
        check("a gap between them is not adjacency", seat_watch.find_adjacent(seats, 2, None), [])
    )

    # Free seats at the ends of different rows are not neighbours either —
    # rows come from the y coordinate, and this is the case a naive scan of
    # the flat seat list gets wrong.
    seats = hall([[False, False, False, True], [True, False, False, False]])
    results.append(
        check("last of one row and first of the next is not a pair", seat_watch.find_adjacent(seats, 2, None), [])
    )

    # --- how many -----------------------------------------------------------
    seats = hall([[True, True, True, False]])
    results.append(check("three in a row, three wanted", len(seat_watch.find_adjacent(seats, 3, None)), 3))
    results.append(
        check("three in a row, four wanted", seat_watch.find_adjacent(seats, 4, None), [])
    )
    results.append(
        check("takes exactly what was asked for", len(seat_watch.find_adjacent(seats, 2, None)), 2)
    )

    # --- categories ---------------------------------------------------------
    seats = hall([[True, True, False]], category=STANDING)
    results.append(
        check("standing places are not seats together", seat_watch.find_adjacent(seats, 2, [STANDING]), [])
    )
    results.append(
        check("…unless nothing is excluded", len(seat_watch.find_adjacent(seats, 2, None)), 2)
    )

    # --- rows that do not line up exactly ------------------------------------
    # Curved blocks put a row's seats a pixel or two apart vertically; they
    # are still one row and still adjacent.
    seats = hall([[True, True]])
    seats[1]["top"] = 202
    results.append(
        check("a two-pixel wobble is still one row", len(seat_watch.find_adjacent(seats, 2, None)), 2)
    )
    # A different block entirely is not.
    seats = hall([[True, True]])
    seats[1]["top"] = 260
    results.append(
        check("a different block is not one row", seat_watch.find_adjacent(seats, 2, None), [])
    )

    # --- parsing the real markup shape --------------------------------------
    payload = (
        "<div class='descr'>7.</div><!-- seats start -->"
        "<div style='left:248px;top:1196px;width:14px;height:14px;cursor:pointer;' "
        "class='position-absolute is_seat ckt_7328  occupied' data-ckt='7328' id='s_0' onclick='P(0);'></div>"
        "<div style='left:266px;top:1196px;width:14px;height:14px;cursor:pointer;' "
        "class='position-absolute is_seat ckt_7323 ' data-ckt='7323' id='s_1' onclick='P(1);'></div>"
    )
    parsed = []
    for match in re.finditer(
        r"<div style='left:(\d+)px;top:(\d+)px;[^']*'\s+class='([^']*is_seat[^']*)'([^>]*)>", payload
    ):
        left, top, classes, _ = match.groups()
        category = re.search(r"ckt_(\d+)", classes)
        parsed.append(
            {
                "left": int(left),
                "top": int(top),
                "occupied": "occupied" in classes,
                "category": category.group(1) if category else None,
            }
        )
    results.append(check("parses both seats", len(parsed), 2))
    results.append(check("reads the occupied flag", [s["occupied"] for s in parsed], [True, False]))
    results.append(check("reads the price category", [s["category"] for s in parsed], ["7328", "7323"]))

    print()
    failed = results.count(False)
    print(f"{len(results) - failed}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
