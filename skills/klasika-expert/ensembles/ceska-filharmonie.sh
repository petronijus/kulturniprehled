#!/usr/bin/env bash
# Scrapes upcoming concerts from ceskafilharmonie.cz/program. Same output
# schema as the other ensemble scrapers — see ../SKILL.md step 5 for the
# normalised JSON shape.
#
# ČF uses Umbraco; each event card is `<div class="event style-default ...">`
# with a `<time datetime="ISO">` for the date and the title inside the
# `event__headline` anchor. Clean structure, stable across reloads.

set -u

# Shared Prague-time helper (see lib/prague_time.py).
export PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib${PYTHONPATH:+:$PYTHONPATH}"

URL="https://www.ceskafilharmonie.cz/program"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="Česká filharmonie"

# The listing is paginated (`/program/?stranka=N`, ~20 cards per page) and the
# season runs Sep–Jun, so page 1 alone is only the next few weeks — that is how
# the 2026-08-16 season run ended up with 3 ČF concerts instead of 20. Walk the
# pages until one yields no event cards, then parse the concatenation.
MAX_PAGES=20
TMP=$(mktemp -t cf-XXXXXX.html)
PAGE_TMP=$(mktemp -t cf-page-XXXXXX.html)
trap 'rm -f "$TMP" "$PAGE_TMP"' EXIT

page=1
while [ "$page" -le "$MAX_PAGES" ]; do
    if [ "$page" -eq 1 ]; then
        PAGE_URL="$URL"
    else
        PAGE_URL="$URL/?stranka=$page"
    fi
    curl -sS -L -A "$UA" --max-time 30 -o "$PAGE_TMP" "$PAGE_URL" 2>/dev/null || break
    [ ! -s "$PAGE_TMP" ] && break
    CARDS=$(grep -c 'class="event style-default' "$PAGE_TMP" || true)
    [ "${CARDS:-0}" -eq 0 ] && break
    cat "$PAGE_TMP" >> "$TMP"
    page=$((page + 1))
    sleep 1   # politeness — this is someone else's server
done

[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, html, json
from prague_time import stamp
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

    # The href carries entities too ("…/38700-&#x10D;esk&#xE1;-filharmonie/"),
    # and an unescaped one becomes both a dead link and an unstable dedup key.
    href, raw_title = html.unescape(h_m.group(1)), h_m.group(2)

    title = html.unescape(re.sub(r'<[^>]+>', '', raw_title))
    title = re.sub(r'\s+', ' ', title).strip()

    # Bare Prague wall time until 2026-09, an entity-escaped offset since.
    dt = stamp(t_m.group(1))
    if dt is None:
        continue

    # ČF renders ONE CARD PER EVENING, every night of a run pointing at the
    # same event URL. Deduplicating on the URL alone therefore kept the first
    # night and silently dropped the rest — Yuja Wang plays 9., 10. and 11.
    # December and the pool held only the 9th. The evening is the identity.
    if (href, dt) in seen:
        continue
    seen.add((href, dt))

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
