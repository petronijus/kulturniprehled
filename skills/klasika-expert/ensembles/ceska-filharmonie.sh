#!/usr/bin/env bash
# Scrapes upcoming concerts from ceskafilharmonie.cz/program. Same output
# schema as the other ensemble scrapers — see ../SKILL.md step 5 for the
# normalised JSON shape.
#
# ČF uses Umbraco; each event card is `<div class="event style-default ...">`
# with a `<time datetime="ISO">` for the date and the title inside the
# `event__headline` anchor. Clean structure, stable across reloads.

set -u

URL="https://www.ceskafilharmonie.cz/program"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="Česká filharmonie"

TMP=$(mktemp -t cf-XXXXXX.html)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 30 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, html, json
src = open(os.environ["HTML_PATH"], encoding="utf-8").read()
ensemble = os.environ["ENSEMBLE"]

cards = re.split(r'<[^>]+class="event\s+style-default', src)
items = []
seen = set()

for c in cards[1:]:
    h_m = re.search(
        r'class="event__headline">.*?<a[^>]+href="([^"]+)"[^>]*>(.+?)</a>',
        c, re.DOTALL,
    )
    t_m = re.search(r'<time[^>]+datetime="([^"]+)"', c)
    if not (h_m and t_m):
        continue

    href, raw_title = h_m.group(1), h_m.group(2)
    if href in seen:
        continue
    seen.add(href)

    title = html.unescape(re.sub(r'<[^>]+>', '', raw_title))
    title = re.sub(r'\s+', ' ', title).strip()

    # datetime looks like "2026-05-25T15:30:00.0000000" — strip fractional second
    dt = re.sub(r'\.\d+$', '', t_m.group(1))
    if 'T' in dt and len(dt) < 25:
        dt = dt + '+02:00'

    items.append({
        "ensemble": ensemble,
        "venue": None,                       # populated below from event__body if available
        "title": title,
        "starts_at": dt,
        "artists": [ensemble],
        "url": "https://www.ceskafilharmonie.cz" + href,
        "price_czk": None,
    })

print(json.dumps(items, ensure_ascii=False))
PY
