"""Programme detail for the four favourite ensembles, read from their own HTML.

Why this exists: the listing pages the scrapers walk carry a marketing title
and nothing else ("LSO • Pappano"), while Petr ranks by composer and work.
Until 2026-09 the programme was filled in exclusively by step 5d of
`klasika-expert`, which pays one WebFetch per candidate under a per-run cap
of 50/60. Two things made that cap a starvation mechanism:

* the cap counts pool rows, and a subscription concert played on three
  evenings is three rows behind ONE detail URL — a quarter of every run's
  budget went on re-fetching pages it had already read that same run;
* the pre-rank is deterministic, so the ensemble it favours wins every run
  and the others never come up. FOK sat at 43 of 66 productions with no
  programme at all, SOČR at 21 of 33, through eight runs.

All four ensembles publish the programme as static server-rendered HTML, so
none of that needs an LLM. Each scraper now fills its own candidates here,
once per detail URL, and step 5d's WebFetch budget is left for the festival
and `objev` sources that genuinely need reading.

A parser that comes back empty says so on stderr (`MISSING_PROGRAM=<url>`)
rather than quietly emitting `program: []` — that line is the signal for
step 5d to spend a WebFetch on the page after all.

Stdlib only, and fetching shells out to the same `curl` the scrapers use:
these hosts already answer it, and a second HTTP client would be a second
set of TLS and redirect quirks to keep working.
"""

from __future__ import annotations

import html as html_mod
import json
import re
import subprocess
import sys
from collections.abc import Callable
from typing import Any

UA = "Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)"

# Separates the works from the performers on a fok.cz card, and shows up as
# an en dash, an em dash or a plain hyphen depending on who typed it.
_DASHES = "–—-"
_BR = re.compile(r"<br\s*/?>", re.I)
_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"\s+")


def _text(fragment: str) -> str:
    """Tags out, entities decoded, whitespace collapsed."""

    return _WS.sub(" ", html_mod.unescape(_TAG.sub(" ", fragment))).strip()


def _lines(fragment: str) -> list[str]:
    """Split on <br> first, so a multi-line <p> keeps its line breaks."""

    return [line for line in (_text(part) for part in _BR.split(fragment)) if line]


def _paragraphs(fragment: str) -> list[str]:
    return re.findall(r"<p\b[^>]*>(.*?)</p>", fragment, re.S | re.I)


def _marked_lines(fragment: str) -> list[tuple[str, bool]]:
    """Every <br>-separated line of a paragraph, with "is it all bold?".

    Both shapes fok.cz uses have to come out the same way: one paragraph per
    programme line, and one paragraph holding the whole programme with <br>
    between the lines. Splitting first and asking about the markup second is
    what makes the two identical to the caller.
    """

    marked: list[tuple[str, bool]] = []
    for segment in _BR.split(fragment):
        text = _text(segment)
        if not text:
            continue
        bold = [_text(s) for s in _strong(segment)]
        marked.append((text, bool(bold) and bold[0] == text))
    return marked


def _strong(fragment: str) -> list[str]:
    return [_text(m) for m in re.findall(r"<strong\b[^>]*>(.*?)</strong>", fragment, re.S | re.I)]


def _section(page: str, heading: str) -> str:
    """The slice between an <h2>/<h3> with this text and the next one."""

    start = re.search(
        rf"<h[23]\b[^>]*>\s*{heading}\s*</h[23]>", html_mod.unescape(page), re.I
    )
    if start is None:
        return ""
    rest = html_mod.unescape(page)[start.end() :]
    stop = re.search(r"<h[23]\b", rest, re.I)
    return rest[: stop.start()] if stop else rest


def _prices(page: str, pattern: str) -> str | None:
    """Normalize any price wording to "<min>–<max>" (or a single number).

    `kp_validate.parse_price` only ever reads the numbers out again, so the
    exact wording carries no information — but a single shape keeps the
    planner's cards from looking like four different websites.
    """

    # ceskafilharmonie.cz serves "Kč" as `K&#x10D;`, so the needle has to be
    # looked for in decoded text or it is never there at all.
    found = re.search(pattern, html_mod.unescape(page), re.I | re.S)
    if found is None:
        return None
    numbers = [
        int(n.replace("\xa0", "").replace(" ", "").replace(".", ""))
        for n in re.findall(r"\d[\d\xa0 .]*", _text(found.group(0)))
    ]
    # A lone "1.200" is a price; a stray "2026" from a nearby date is not.
    numbers = [n for n in numbers if 30 <= n <= 30000]
    if not numbers:
        return None
    low, high = min(numbers), max(numbers)
    return str(low) if low == high else f"{low}–{high}"


# A venue that has not settled its repertoire yet says so on the page. That
# is a different answer from "we failed to read it", and only the second one
# is worth spending a WebFetch on — so the two never share a code path.
_UNPUBLISHED = (
    "program připravujeme",
    "program bude upřesněn",
    "program bude zveřejněn",
    "programme to be announced",
)


def program_note(page: str) -> str | None:
    lowered = _text(page).lower()
    for phrase in _UNPUBLISHED:
        if phrase in lowered:
            return "Pořadatel program zatím nezveřejnil."
    return None


def _tickets(page: str, buy: tuple[str, ...]) -> bool | None:
    lowered = page.lower()
    for sold_out in ("vyprodáno", "vyprodano", "sold out", "nedostupné"):
        if sold_out in lowered:
            return False
    return True if any(token.lower() in lowered for token in buy) else None


# socr.rozhlas.cz prints each piece's playing time after the title —
# "Římské pinie (23‘)". It is not part of the work and no catalogue carries
# it, so leaving it in poisons the Spotify lookup: the stray number reaches
# `program-links` as another digit to match on, and Bernstein's "Symfonie
# č. 2 „Věk úzkosti“ (35´)" came back as Bach and Semafor.
_DURATION = re.compile(r"\s*[(\[]\s*\d{1,3}\s*['‘’´ʹ′]?\s*[)\]]\s*$")


def _entry(composer: str, work: str | None = None) -> dict[str, str]:
    """One programme line. `work` stays absent when the page names none.

    A gala that bills only its composers ("Widor, Franck, Nowowiejski") is
    still worth ranking on, but it must not claim a work: `work_keys` in
    kp_validate and `candidateWorkKeys` in the SPA both require a string on
    each side, so an entry without one is read for its composer and skipped
    by the duplicate-work rule — which is exactly right, since two galas of
    the same composer are not the same piece twice.
    """

    trimmed = composer.strip(" .:–—-")
    if work is None:
        return {"composer": trimmed}
    return {"composer": trimmed, "work": _DURATION.sub("", work).strip(" .:–—-")}


# --------------------------------------------------------------------------
# ceskafilharmonie.cz — <h2>Program</h2> then <p><strong>X</strong><br>work
# --------------------------------------------------------------------------
def parse_cf(page: str) -> dict[str, Any]:
    program: list[dict[str, str]] = []
    for block in _paragraphs(_section(page, "Program")):
        names = _strong(block)
        if not names:
            continue
        composer = names[0]
        for work in _lines(_BR.split(block, 1)[-1] if _BR.search(block) else ""):
            if work and work != composer:
                program.append(_entry(composer, work))

    soloists: list[str] = []
    conductor: str | None = None
    for block in _paragraphs(_section(page, "Účinkující")):
        names = _strong(block)
        if not names:
            continue
        role = _text(re.search(r"<em\b[^>]*>(.*?)</em>", block, re.S | re.I).group(1)) if re.search(
            r"<em\b[^>]*>(.*?)</em>", block, re.S | re.I
        ) else ""
        if "dirigent" in role.lower():
            conductor = names[0]
        elif role:
            soloists.append(names[0])

    return {
        "program": program,
        "soloists": soloists,
        "conductor": conductor,
        "price_czk": _prices(page, r"Cena[^<]{0,40}Kč"),
        "tickets_available": _tickets(page, ("objednat online", "koupit")),
    }


# --------------------------------------------------------------------------
# fok.cz — <div class="repertoar">, works above a lone dash, cast below it
# --------------------------------------------------------------------------
def parse_fok(page: str) -> dict[str, Any]:
    opening = re.search(r'<div class="repertoar[^"]*"[^>]*>', page, re.I)
    if opening is None:
        return _empty(page, ("koupit vstupenku",))
    # Balanced, not `(.*?)</div>`: the block is flat <p> today, but a single
    # wrapper div added by a redesign would otherwise empty the whole lane.
    block = _div_block(page, opening.start())

    program: list[dict[str, str]] = []
    soloists: list[str] = []
    conductor: str | None = None
    composer: str | None = None
    composer_had_work = False
    past_cast_separator = False

    def flush() -> None:
        # A composer whose works were never printed is still the programme.
        if composer is not None and not composer_had_work:
            program.append(_entry(composer))

    for raw in _paragraphs(block):
        for line, bold in _marked_lines(raw):
            # A line holding nothing but a dash divides works from cast.
            if all(ch in _DASHES + " " for ch in line):
                flush()
                past_cast_separator = True
                composer = None
                continue

            if past_cast_separator:
                if not bold and "|" not in line:
                    continue
                name, _, role = line.partition("|")
                if "dirigent" in role.lower():
                    conductor = name.strip()
                elif role.strip():
                    soloists.append(name.strip())
                continue

            # Above the separator a bold line names a composer and the plain
            # lines under it are that composer's works — one composer can
            # carry several (a whole-evening Čajkovskij, say).
            if bold:
                flush()
                composer = line
                composer_had_work = False
            elif composer is not None:
                program.append(_entry(composer, line))
                composer_had_work = True
            # else: a subtitle printed before any composer ("Koncert pro
            # republiku") — it names no work, so it is not one.
    flush()

    return {
        "program": program,
        "soloists": soloists,
        "conductor": conductor,
        "price_czk": _prices(page, r"Ceny vstupenek.{0,120}?Kč"),
        "tickets_available": _tickets(page, ("koupit vstupenku",)),
    }


# --------------------------------------------------------------------------
# socr.rozhlas.cz — one <p> of <br>-separated "Composer: Work" / "Name – role"
# --------------------------------------------------------------------------
_WORK_LINE = re.compile(r"^(?P<composer>[^:]{2,60}):\s*(?P<work>.+)$")
# The separator has to be surrounded by spaces, or a hyphenated surname
# splits itself: "Milan Al-Ashhab — housle" is one violinist, not "Milan Al".
_CAST_LINE = re.compile(rf"^(?P<name>.{{2,60}}?)\s+[{_DASHES}]\s+(?P<role>.{{2,40}})$")


def parse_socr(page: str) -> dict[str, Any]:
    body = re.search(
        r'<div class="field body"[^>]*>(.*?)(?=<div class="field |\Z)', page, re.S | re.I
    )
    haystack = body.group(1) if body else page

    best: dict[str, Any] | None = None
    for raw in _paragraphs(haystack):
        lines = _lines(raw)
        # The programme block is short lines, most of them "Composer: Work"
        # or "Name – role". Prose paragraphs also carry <strong> and colons,
        # so shape is what tells them apart, not markup.
        if len(lines) < 2 or any(len(line) > 140 for line in lines):
            continue
        program: list[dict[str, str]] = []
        soloists: list[str] = []
        conductor: str | None = None
        for line in lines:
            cast = _CAST_LINE.match(line)
            if cast is not None and ":" not in line:
                role = cast.group("role").lower()
                if "dirigent" in role:
                    conductor = cast.group("name").strip()
                else:
                    soloists.append(cast.group("name").strip())
                continue
            work = _WORK_LINE.match(line)
            if work is not None:
                program.append(_entry(work.group("composer"), work.group("work")))
        if program and (best is None or len(program) > len(best["program"])):
            best = {"program": program, "soloists": soloists, "conductor": conductor}
        if best is not None:
            break

    resolved = best or {"program": [], "soloists": [], "conductor": None}
    return {
        **resolved,
        "price_czk": _prices(page, r"Cena vstupenek[^<]{0,60}Kč"),
        "tickets_available": _tickets(page, ("koupit vstupenku",)),
    }


# --------------------------------------------------------------------------
# prgphil.cz — Drupal field--name-field-program[-alternativa]
# --------------------------------------------------------------------------
_DIV = re.compile(r"<div\b[^>]*>|</div>", re.I)


def _div_block(page: str, start: int) -> str:
    """The contents of the <div> that opens at `start`, nesting respected.

    A non-greedy `(.*?)</div>` stops at the first inner close, which for the
    Drupal programme field — divs four deep — is the opening tag's own line.
    """

    depth = 0
    for match in _DIV.finditer(page, start):
        depth += -1 if match.group(0).startswith("</") else 1
        if depth == 0:
            return page[page.index(">", start) + 1 : match.start()]
    return page[start:]


def _pkf_field(page: str, name: str) -> str:
    found = re.search(
        # The class token has to end here: without the lookahead, asking for
        # "program" also matches "program-alternativa" and the two fields swap.
        rf'<div class="field field--name-field-{name}(?=[\s"])[^"]*"[^>]*>', page, re.I
    )
    return _div_block(page, found.start()) if found else ""


def parse_pkf(page: str) -> dict[str, Any]:
    # prgphil.cz carries the programme twice: as Drupal paragraph entities
    # (`bod-programu`, one composer + one work per item) and as a free-text
    # "alternativa" field. The entities are authored per field and cannot
    # run the two together, so they are read first and the text is a
    # fallback for the concerts that only got the prose version.
    program: list[dict[str, str]] = [
        _entry(composer, work)
        for composer, work in re.findall(
            r'field--name-field-skladatel[^>]*>(.*?)</div>.*?'
            r'field--name-field-skladba[^>]*>(.*?)</div>',
            _pkf_field(page, "program"),
            re.S | re.I,
        )
    ]
    if not program:
        for block in _paragraphs(_pkf_field(page, "program-alternativa")):
            lines = _marked_lines(block)
            composer: str | None = None
            for line, bold in lines:
                if bold:
                    composer = line
                elif composer is not None:
                    program.append(_entry(composer, line))

    soloists: list[str] = []
    conductor: str | None = None
    for name in ("interpreti-alternativa", "interpreti"):
        field = _pkf_field(page, name)
        if not field:
            continue
        for block in _paragraphs(field):
            for line in _lines(block):
                cast = _CAST_LINE.match(line)
                if cast is None:
                    continue
                if "dirigent" in cast.group("role").lower():
                    conductor = cast.group("name").strip()
                else:
                    soloists.append(cast.group("name").strip())
        if soloists or conductor:
            break

    return {
        "program": program,
        "soloists": soloists,
        "conductor": conductor,
        # prgphil.cz prints one price per category ("450 Kč | 350 Kč | 200 Kč"),
        # so the match has to run to the end of the paragraph — stopping at the
        # first "Kč" would report the top tier as the whole range.
        "price_czk": _prices(page, r"Vstupenky:.{0,200}?</p>"),
        "tickets_available": _tickets(page, ("koupit", "do košíku", "vstupenky")),
    }


def _empty(page: str, buy: tuple[str, ...]) -> dict[str, Any]:
    return {
        "program": [],
        "soloists": [],
        "conductor": None,
        "price_czk": None,
        "tickets_available": _tickets(page, buy),
    }


PARSERS: dict[str, Callable[[str], dict[str, Any]]] = {
    "cf": parse_cf,
    "fok": parse_fok,
    "socr": parse_socr,
    "pkf": parse_pkf,
}


# Seconds between detail fetches, per host. fok.cz stopped answering this
# machine entirely after a ~60-page pass at one request per second (2026-09-20)
# and stayed dark for minutes; the others took the same pass without complaint.
# Slower there is not politeness theatre, it is the difference between a full
# lane and an empty one.
DELAYS = {"fok": 3.0, "cf": 1.0, "socr": 1.0, "pkf": 1.0}

# A host that has started refusing will not change its mind inside one run, so
# the pass gives up rather than spending the rest of the season's goodwill.
_GIVE_UP_AFTER = 3


def fetch(url: str, *, timeout: int = 30) -> str | None:
    try:
        done = subprocess.run(
            ["curl", "-sS", "-L", "-A", UA, "--max-time", str(timeout), url],
            capture_output=True,
            timeout=timeout + 10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0 or not done.stdout:
        return None
    return done.stdout.decode("utf-8", errors="replace")


def enrich(items: list[dict[str, Any]], site: str, *, delay: float | None = None) -> None:
    """Fill `program` / `soloists` / `conductor` / `price_czk` in place.

    One fetch per distinct detail URL, shared by every evening of the run —
    that dedup is the whole point, so never make this per item.
    """

    parser = PARSERS[site]
    delay = DELAYS[site] if delay is None else delay
    consecutive_failures = 0
    by_url: dict[str, list[dict[str, Any]]] = {}
    for item in items:
        url = item.get("url")
        if isinstance(url, str) and url:
            by_url.setdefault(url, []).append(item)

    for index, (url, group) in enumerate(by_url.items()):
        if index and delay:
            _sleep(delay)
        page = fetch(url)
        if page is None:
            # One slow answer is noise; give it a breath and ask again.
            _sleep(delay * 5)
            page = fetch(url)
        if page is None:
            consecutive_failures += 1
            print(f"WARN: detail fetch failed {url}", file=sys.stderr)
            if consecutive_failures >= _GIVE_UP_AFTER:
                print(
                    f"WARN: {site} stopped answering after {index} of {len(by_url)} "
                    "productions — detail pass abandoned, the rest keep the listing "
                    "only (step 5d will see them as MISSING_PROGRAM)",
                    file=sys.stderr,
                )
                return
            continue
        consecutive_failures = 0
        try:
            detail = parser(page)
        except Exception as exc:  # a layout change must not kill the lane
            print(f"WARN: detail parse failed {url}: {exc}", file=sys.stderr)
            continue
        if not detail["program"]:
            note = program_note(page)
            if note is None:
                # Step 5d reads this line and spends a WebFetch on the page.
                print(f"MISSING_PROGRAM={url}", file=sys.stderr)
            else:
                # The venue itself says there is nothing to read yet, so no
                # amount of re-reading the page will produce a programme.
                detail["program_note"] = note
                print(f"PROGRAM_UNPUBLISHED={url}", file=sys.stderr)
        for item in group:
            for key, value in detail.items():
                # The listing wins where it already knows better (a price
                # printed per evening, a venue named on the card).
                if value not in (None, [], "") and not item.get(key):
                    item[key] = value


def _sleep(seconds: float) -> None:
    import time

    time.sleep(seconds)


def main() -> int:
    """`python3 -m detail <site> <url>` — parse one page, print the JSON.

    The scrapers do not use this; it is how you check a parser after one of
    these four sites has been redesigned.
    """

    if len(sys.argv) != 3 or sys.argv[1] not in PARSERS:
        print(f"usage: detail.py <{'|'.join(PARSERS)}> <url>", file=sys.stderr)
        return 2
    page = fetch(sys.argv[2])
    if page is None:
        print("fetch failed", file=sys.stderr)
        return 1
    print(json.dumps(PARSERS[sys.argv[1]](page), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
