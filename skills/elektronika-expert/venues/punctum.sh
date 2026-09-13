#!/usr/bin/env bash
# Scrapes upcoming events from Punctum / Krásovka. Same output schema as the
# klasika ensemble scrapers — see ../../klasika-expert/SKILL.md step 5.
#
# punctum.cz is a Vite SPA: every path returns the same 5.8 kB shell, which is
# why WebFetch read it as an empty page from 2026-08 until this scraper existed.
# The site publishes a full RSS feed instead — 24 upcoming events with
# xcal:dtstart, xcal:location and xcal:url — so the feed is the source here.

set -u

# Shared Prague-time helper (see ../../klasika-expert/ensembles/lib).
export PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../klasika-expert/ensembles/lib${PYTHONPATH:+:$PYTHONPATH}"

URL="https://punctum.cz/rss"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
VENUE_NAME="Punctum"

TMP=$(mktemp -t punctum-XXXXXX.xml)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 30 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

XML_PATH="$TMP" VENUE="$VENUE_NAME" python3 - <<'PY'
import os, re, html, json
from prague_time import stamp

src = open(os.environ["XML_PATH"], encoding="utf-8").read()
venue = os.environ["VENUE"]

def tag(block, name):
    m = re.search(rf"<{name}>(.*?)</{name}>", block, re.DOTALL)
    return html.unescape(m.group(1)).strip() if m else None

items = []
for block in re.findall(r"<item>(.*?)</item>", src, re.DOTALL):
    title = tag(block, "title")
    start = tag(block, "xcal:dtstart")
    if not (title and start):
        continue
    starts_at = stamp(start)
    if starts_at is None:
        continue
    # Punctum runs workshops, yoga and readings in the same feed as the gigs;
    # the lane is music, so the obvious non-concerts go.
    low = title.lower()
    if any(w in low for w in ("workshop", "jóga", "joga", "yoga", "čtení", "cteni",
                              "přednáška", "prednaska", "diskuze", "kurz")):
        continue
    items.append({
        "ensemble": None,
        "venue": tag(block, "xcal:location") or venue,
        "title": re.sub(r"\s+", " ", title),
        "starts_at": starts_at,
        "artists": [],
        "url": tag(block, "xcal:url") or tag(block, "link"),
        "price_czk": None,
    })

print(json.dumps(items, ensure_ascii=False))
PY
