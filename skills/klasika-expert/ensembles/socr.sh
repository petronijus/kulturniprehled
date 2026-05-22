#!/usr/bin/env bash
# Scrapes upcoming concerts from socr.rozhlas.cz/koncerty-a-vstupenky
# (Symfonický orchestr Českého rozhlasu). Cards are `<li class="b-099d__list-item">`
# (Drupal block 099d) with title in `<h3><a href>...</a></h3>` and a Czech
# date string in the following `<p>` (e.g. "Rudolfinum, pondělí 15. 6. 2026
# v 19.30 hodin").

set -u

URL="https://socr.rozhlas.cz/koncerty-a-vstupenky"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="SOČR – Symfonický orchestr Českého rozhlasu"

TMP=$(mktemp -t socr-XXXXXX.html)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 30 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, html, json
src = open(os.environ["HTML_PATH"], encoding="utf-8").read()
ensemble = os.environ["ENSEMBLE"]

# Cards live inside the SOČR concerts Drupal view. Split by `b-099d__list-item`
# OR by the more generic `<h3><a href>...` pattern within that block. The
# latter is safer (the class name might rotate); just pull every h3-anchor that
# has a Czech-date <p> immediately after.
items = []
seen = set()

for m in re.finditer(
    r'<h3>\s*<a\s+href="(/[^"]+)"[^>]*>([^<]+)</a>\s*</h3>\s*'
    r'(?:<a[^>]*>)?\s*<p>([^<]+)</p>',
    src,
):
    href, title_raw, desc = m.groups()
    if href in seen:
        continue

    d_m = re.search(
        r'(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})(?:\s+v\s+(\d{1,2})[\.:](\d{2}))?',
        desc,
    )
    if not d_m:
        continue
    seen.add(href)

    day, mo, yr = (int(x) for x in d_m.groups()[:3])
    hh = int(d_m.group(4)) if d_m.group(4) else 19
    mm = int(d_m.group(5)) if d_m.group(5) else 30

    title = html.unescape(title_raw).strip()
    venue = desc.split(',', 1)[0].strip() or None

    items.append({
        "ensemble": ensemble,
        "venue": venue,
        "title": title,
        "starts_at": f"{yr:04d}-{mo:02d}-{day:02d}T{hh:02d}:{mm:02d}:00+02:00",
        "artists": [ensemble],
        "url": "https://socr.rozhlas.cz" + href,
        "price_czk": None,
    })

print(json.dumps(items, ensure_ascii=False))
PY
