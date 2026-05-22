#!/usr/bin/env bash
# Scrapes upcoming concerts from prgphil.cz/koncerty-a-vstupenky (PKF –
# Prague Philharmonia). Cards are wrapped in `<div class="vypis-ko-flex">`;
# title in `<h3 class="nadpis"><span>...</span></h3>`; date in two pieces:
# `class="date-1">DD. MM. YY` + `class="date-2">DOW • HH:MM`.

set -u

URL="https://www.prgphil.cz/koncerty-a-vstupenky"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="PKF – Prague Philharmonia"

TMP=$(mktemp -t pkf-XXXXXX.html)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 30 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, html, json
src = open(os.environ["HTML_PATH"], encoding="utf-8").read()
ensemble = os.environ["ENSEMBLE"]

cards = re.split(r'<div class="vypis-ko-flex">', src)
items = []
seen = set()

for c in cards[1:]:
    h_m = re.search(r'<a href="(/[^"]+)" class="vypis-ko-obsah-a"', c)
    title_m = re.search(r'<h3 class="nadpis">\s*<span>(.+?)</span>\s*</h3>', c, re.DOTALL)
    d1_m = re.search(r'class="date-1">\s*(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{2})', c)
    d2_m = re.search(r'class="date-2">[^<]*?•\s*(\d{1,2}):(\d{2})', c)

    if not (h_m and title_m and d1_m):
        continue

    href = h_m.group(1)
    if href in seen:
        continue
    seen.add(href)

    title = html.unescape(re.sub(r'<[^>]+>', '', title_m.group(1)).strip())
    title = re.sub(r'\s+', ' ', title)

    day, mo, yy = (int(x) for x in d1_m.groups())
    yr = 2000 + yy
    if d2_m:
        hh, mm = (int(x) for x in d2_m.groups())
    else:
        hh, mm = 19, 30

    items.append({
        "ensemble": ensemble,
        "venue": None,
        "title": title,
        "starts_at": f"{yr:04d}-{mo:02d}-{day:02d}T{hh:02d}:{mm:02d}:00+02:00",
        "artists": [ensemble],
        "url": "https://www.prgphil.cz" + href,
        "price_czk": None,
    })

print(json.dumps(items, ensure_ascii=False))
PY
