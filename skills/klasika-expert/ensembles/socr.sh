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

# Drupal pager (`?page=N`, zero-based). Page 0 is roughly the next two months,
# so the season tail was missing until 2026-08-16.
MAX_PAGES=20
TMP=$(mktemp -t socr-XXXXXX.html)
PAGE_TMP=$(mktemp -t socr-page-XXXXXX.html)
trap 'rm -f "$TMP" "$PAGE_TMP"' EXIT

page=0
while [ "$page" -lt "$MAX_PAGES" ]; do
    curl -sS -L -A "$UA" --max-time 30 -o "$PAGE_TMP" "$URL?page=$page" 2>/dev/null || break
    [ ! -s "$PAGE_TMP" ] && break
    # Count cards with the SAME pattern the parser uses below — the block's
    # class name rotates (b-099d → b-004 sometime before 2026-08), and keying
    # the loop on the class silently emptied the whole lane.
    CARDS=$(python3 -c "
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
print(len(re.findall(r'<h3>\s*<a\s+href=\"/[^\"]+\"', src)))
" "$PAGE_TMP" 2>/dev/null || echo 0)
    [ "${CARDS:-0}" -eq 0 ] && break
    cat "$PAGE_TMP" >> "$TMP"
    page=$((page + 1))
    sleep 1   # politeness
done

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

    # socr.rozhlas.cz has switched between numeric ("15. 6. 2026 v 19.30")
    # and worded ("24. září 2026 ve 20.00") date formats — accept both,
    # including the "v"/"ve" preposition variants.
    CZ_MONTHS = {
        'ledna': 1, 'unora': 2, 'února': 2, 'brezna': 3, 'března': 3,
        'dubna': 4, 'kvetna': 5, 'května': 5, 'cervna': 6, 'června': 6,
        'cervence': 7, 'července': 7, 'srpna': 8, 'zari': 9, 'září': 9,
        'rijna': 10, 'října': 10, 'listopadu': 11, 'prosince': 12,
    }
    d_m = re.search(
        r'(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})(?:\s+ve?\s+(\d{1,2})[\.:](\d{2}))?',
        desc,
    )
    if d_m:
        day, mo, yr = (int(x) for x in d_m.groups()[:3])
    else:
        d_m = re.search(
            r'(\d{1,2})\.\s*([a-záéíóúůýčďěňřšťž]+)\s*(\d{4})'
            r'(?:\s+ve?\s+(\d{1,2})[\.:](\d{2}))?',
            desc, re.IGNORECASE,
        )
        if not d_m or d_m.group(2).lower() not in CZ_MONTHS:
            continue
        day = int(d_m.group(1))
        mo = CZ_MONTHS[d_m.group(2).lower()]
        yr = int(d_m.group(3))
    seen.add(href)

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
