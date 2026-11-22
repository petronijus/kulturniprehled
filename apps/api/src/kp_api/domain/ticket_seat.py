"""Read the seat printed on one ticket page ("Přízemí vpravo · Řada 10 ·
Místo 19"), so the phone can show it above that ticket's code.

The label is built from the ticket's own words — the venue's section name
and its "Řada" / "Místo" / "Sedadlo" — not translated. The layouts seen so
far print the row and the seat as labelled fields, either on one line
("Řada 10, Místo 19") or on their own lines ("Řada|Row: 5", "SEDADLO 27"),
and the section as a labelled field ("Sektor:", "Umístění|Location:" with
"Strana|Side:", "PODLAŽÍ" with "STRANA") or as the unlabelled line right
above the row. A page whose seat is not labelled ("Přízemí vlevo 6 11"), or
that holds more than one seat, gets no label: a wrong seat at the door is
worse than none.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

_NUMBER = r"(\d{1,4}[A-Za-z]?)"
_ROW = re.compile(rf"^(?P<word>[řr]ada)(?:\s*\|\s*row)?\s*:?\s*{_NUMBER}$", re.IGNORECASE)
_SEAT = re.compile(
    rf"^(?P<word>m[íi]sto|sedadlo)(?:\s*\|\s*seat)?\s*:?\s*{_NUMBER}$", re.IGNORECASE
)
_ROW_AND_SEAT = re.compile(
    rf"^(?P<rword>[řr]ada)(?:\s*\|\s*row)?\s*:?\s*{_NUMBER}\s*,\s*"
    rf"(?P<sword>m[íi]sto|sedadlo)(?:\s*\|\s*seat)?\s*:?\s*{_NUMBER}$",
    re.IGNORECASE,
)
_SECTION_FIELDS = (
    re.compile(r"^sektor(?:\s*\|\s*sector)?\s*:\s*(?P<value>.+)$", re.IGNORECASE),
    re.compile(r"^um[íi]st[ěe]n[íi](?:\s*\|\s*location)?\s*:\s*(?P<value>.+)$", re.IGNORECASE),
    re.compile(r"^podla[žz][íi]\s+(?P<value>.+)$", re.IGNORECASE),
)
_SIDE_FIELD = re.compile(r"^strana(?:\s*\|\s*side)?\s*:?\s*(?P<value>.+)$", re.IGNORECASE)


@dataclass(frozen=True)
class _Seat:
    row_word: str
    row: str
    seat_word: str
    seat: str
    row_line: int


def _lines(text: str) -> list[str]:
    return [" ".join(line.replace("\xa0", " ").split()) for line in text.splitlines()]


def _word(word: str) -> str:
    return word[:1].upper() + word[1:].lower()


def _seats(lines: list[str]) -> list[_Seat]:
    seats: list[_Seat] = []
    for index, line in enumerate(lines):
        both = _ROW_AND_SEAT.match(line)
        if both:
            seats.append(_Seat(both["rword"], both[2], both["sword"], both[4], index))
            continue
        row = _ROW.match(line)
        if row is None:
            continue
        # The seat is the next labelled seat line, a line or two below.
        for follower in lines[index + 1 : index + 3]:
            seat = _SEAT.match(follower)
            if seat:
                seats.append(_Seat(row["word"], row[2], seat["word"], seat[2], index))
                break
    return seats


def _field(lines: list[str], pattern: re.Pattern[str]) -> str | None:
    for line in lines:
        match = pattern.match(line)
        if match and match["value"].strip():
            return match["value"].strip()
    return None


def _section(lines: list[str], row_line: int) -> str | None:
    section = next(
        (value for p in _SECTION_FIELDS if (value := _field(lines, p)) is not None), None
    )
    side = _field(lines, _SIDE_FIELD)
    if section is None and row_line > 0:
        above = lines[row_line - 1]
        # An unlabelled section line: words only, no price, date or field.
        if above and not re.search(r"[\d:|]", above):
            section = above
    if section and side and side.lower() not in section.lower():
        section = f"{section} {side}"
    return section


def seat_label(page_text: str) -> str | None:
    """The page's seat as "<section> · Řada <n> · Místo <n>", or None when
    the page names no seat or more than one."""

    lines = _lines(page_text)
    seats = _seats(lines)
    if len({(s.row, s.seat) for s in seats}) != 1:
        return None
    seat = seats[0]
    parts = [
        _section(lines, seat.row_line),
        f"{_word(seat.row_word)} {seat.row}",
        f"{_word(seat.seat_word)} {seat.seat}",
    ]
    return " · ".join(part for part in parts if part)
