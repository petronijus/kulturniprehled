#!/usr/bin/env bash
# Scrapes upcoming concerts from prgphil.cz/koncerty-a-vstupenky (PKF –
# Prague Philharmonia). Title in `<h3 class="nadpis"><span>...</span></h3>`
# inside `<div class="vypis-ko-flex">`; date in two pieces just ABOVE that
# wrapper: `class="date-1">DD. MM. YY` + `class="date-2">DOW • HH:MM`.
#
# The date sitting OUTSIDE the card is the whole difficulty. Splitting on the
# card wrapper puts each card together with the NEXT card's date, and the
# result is plausible enough to go unnoticed: every PKF concert in the
# 2026/27 pool was filed under the following concert's date and time until
# 2026-09-13, when a planned evening turned out to be on a day the orchestra
# was not playing. So split on the DATE and take the card that follows it,
# and check the pairing against the detail page before trusting a change to
# this file — every one of the 50 cards was wrong, and all 50 looked fine.

set -u

# Shared Prague-time helper (see lib/prague_time.py).
export PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib${PYTHONPATH:+:$PYTHONPATH}"

URL="https://www.prgphil.cz/koncerty-a-vstupenky"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="PKF – Prague Philharmonia"

TMP=$(mktemp -t pkf-XXXXXX.html)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 30 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, sys, html, json
from prague_time import prague_parts
src = open(os.environ["HTML_PATH"], encoding="utf-8").read()
ensemble = os.environ["ENSEMBLE"]

# Each chunk begins at a date and runs to the next one, so it holds that
# date and the card it belongs to.
cards = re.split(r'class="date-1">', src)
items = []
seen = set()
previous = None

for c in cards[1:]:
    h_m = re.search(r'<a href="(/[^"]+)" class="vypis-ko-obsah-a"', c)
    title_m = re.search(r'<h3 class="nadpis">\s*<span>(.+?)</span>\s*</h3>', c, re.DOTALL)
    d1_m = re.match(r'\s*(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{2})', c)
    d2_m = re.search(r'class="date-2">[^<]*?•\s*(\d{1,2}):(\d{2})', c)

    if not (h_m and title_m and d1_m):
        continue

    href = h_m.group(1)

    title = html.unescape(re.sub(r'<[^>]+>', '', title_m.group(1)).strip())
    title = re.sub(r'\s+', ' ', title)

    day, mo, yy = (int(x) for x in d1_m.groups())
    yr = 2000 + yy
    if d2_m:
        hh, mm = (int(x) for x in d2_m.groups())
    else:
        hh, mm = 19, 30

    starts_at = prague_parts(yr, mo, day, hh, mm)
    # The evening is the identity, not the page: prgphil.cz prints one card
    # per evening but a repeated concert shares its detail URL, so keying the
    # dedup on the href alone silently threw the second night away — the same
    # bug fok.cz and socr.rozhlas.cz were fixed for in 2026-09.
    if (href, starts_at) in seen:
        continue
    seen.add((href, starts_at))

    # The listing is chronological. A date that goes backwards means the
    # pairing has slipped again — say so instead of emitting a wrong evening.
    if previous is not None and starts_at < previous:
        print(f"WARN: pkf listing is out of order at {starts_at} "
              f"(previous {previous}) — date/title pairing is suspect",
              file=sys.stderr)
    previous = starts_at

    items.append({
        "ensemble": ensemble,
        "venue": None,
        "title": title,
        "starts_at": starts_at,
        "artists": [ensemble],
        "url": "https://www.prgphil.cz" + href,
        "price_czk": None,
    })

# The listing knows the title and the evening; the programme lives on the
# detail page. Reading it here — once per production URL, not once per
# evening — is what keeps a card from reaching the planner empty. Set
# KP_SKIP_DETAILS=1 to emit the listing alone (faster, for parser work on
# the listing itself).
if not os.environ.get("KP_SKIP_DETAILS"):
    import detail
    detail.enrich(items, "pkf")

print(json.dumps(items, ensure_ascii=False))
PY
