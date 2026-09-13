#!/usr/bin/env bash
# Scrapes upcoming concerts from fok.cz/cs/program (Symfonický orchestr
# hl. m. Prahy FOK). Cards are `class="Program-item ..."` with a clean
# `<time datetime>` and a first-text-snippet title after the `</picture>`.

set -u

# Shared Prague-time helper (see lib/prague_time.py).
export PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib${PYTHONPATH:+:$PYTHONPATH}"

URL="https://www.fok.cz/cs/program"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="FOK – Symfonický orchestr hl. m. Prahy"

# Paginated `?page=N`, zero-based, ~15 cards per page — page 0 alone stops
# months short of the season end (found in the 2026-08-16 season run).
MAX_PAGES=20
TMP=$(mktemp -t fok-XXXXXX.html)
PAGE_TMP=$(mktemp -t fok-page-XXXXXX.html)
trap 'rm -f "$TMP" "$PAGE_TMP"' EXIT

page=0
while [ "$page" -lt "$MAX_PAGES" ]; do
    curl -sS -L -A "$UA" --max-time 30 -o "$PAGE_TMP" "$URL?page=$page" 2>/dev/null || break
    [ ! -s "$PAGE_TMP" ] && break
    CARDS=$(grep -c 'class="Program-item ' "$PAGE_TMP" || true)
    [ "${CARDS:-0}" -eq 0 ] && break
    cat "$PAGE_TMP" >> "$TMP"
    page=$((page + 1))
    sleep 1   # politeness
done

[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, html, json
from prague_time import stamp
src = open(os.environ["HTML_PATH"], encoding="utf-8").read()
ensemble = os.environ["ENSEMBLE"]

cards = re.split(r'<[^>]+class="Program-item\s', src)
items = []
seen = set()

for c in cards[1:]:
    h_m = re.search(r'<a href="(/[^"]+)">', c)
    # A card carries EVERY evening of the run — two `<time>` elements for a
    # Wednesday/Thursday pair. Reading only the first, and then discarding
    # repeats of the URL, threw the other nights away without a trace.
    stamps = re.findall(r'<time datetime="([^"]+)"', c)
    if not (h_m and stamps):
        continue

    href = h_m.group(1)

    # Title is the first decent text snippet after the </picture> close
    title = ""
    after = c.split("</picture>", 1)[-1] if "</picture>" in c else c
    for tx in re.findall(r">([^<\n]{8,200})<", after[:5000]):
        tx = html.unescape(tx).strip()
        if tx and not tx.startswith("?") and "webp" not in tx and ".jpg" not in tx \
                and "Koupit" not in tx and not re.match(r"^\d+\.\s*\d+\.", tx):
            title = tx
            break
    if not title:
        continue

    for raw in stamps:
        # FOK closes its stamps with `Z` and then prints the same digits as
        # the local start time — the suffix is decoration, not a timezone.
        starts_at = stamp(raw, trust_offset=False)
        if starts_at is None or (href, starts_at) in seen:
            continue
        seen.add((href, starts_at))
        items.append({
            "ensemble": ensemble,
            "venue": None,
            "title": title,
            "starts_at": starts_at,
            "artists": [ensemble],
            "url": "https://www.fok.cz" + href,
            "price_czk": None,
        })

print(json.dumps(items, ensure_ascii=False))
PY
