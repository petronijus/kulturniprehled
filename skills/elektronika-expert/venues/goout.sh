#!/usr/bin/env bash
# Scrapes one GoOut page — a promoter, a venue or a city listing — for its
# server-rendered events. Usage: goout.sh <goout-url>
#
# Two shapes, both handled here:
#   * listings (goout.net/cs/praha/koncerty/…) embed schema.org Event blocks
#     as application/ld+json, with name, startDate, location and url;
#   * promoter and venue pages render `schedule-row` markup instead.
#
# What this cannot do, and no prompt will change: the `?tags=…` filter on a
# listing is applied in the browser, so the server always returns the whole
# unfiltered page (checked 2026-09-13 — `?tags=electronic` came back as
# post-punk and jazz). Filter by tag on OUR side, or pass a promoter page.
# Promoter pages server-render only the nearest date and lazy-load the rest
# behind "Zobrazit další", so treat their output as "the next one", not "the
# season".

set -u

export PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../klasika-expert/ensembles/lib${PYTHONPATH:+:$PYTHONPATH}"

URL="${1:?usage: goout.sh <goout-url>}"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'

TMP=$(mktemp -t goout-XXXXXX.html)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 40 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" PAGE_URL="$URL" python3 - <<'PY'
import os, re, html, json
from datetime import datetime
from prague_time import prague_parts, stamp

src = open(os.environ["HTML_PATH"], encoding="utf-8").read()
items, seen = [], set()

def add(title, starts_at, venue, url, price=None):
    if not (title and starts_at and url) or url in seen:
        return
    seen.add(url)
    items.append({"ensemble": None, "venue": venue, "title": re.sub(r"\s+", " ", title).strip(),
                  "starts_at": starts_at, "artists": [], "url": url, "price_czk": price})

# --- shape 1: schema.org Event blocks (city / genre listings) ----------------
for block in re.findall(r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>', src, re.S):
    try:
        payload = json.loads(block)
    except ValueError:
        continue
    for node in payload if isinstance(payload, list) else [payload]:
        if node.get("@type") != "Event":
            continue
        # GoOut prints a JS Date toString ("Sun Sep 13 2026 18:00:00 GMT+0000"),
        # not ISO — parse it as UTC and let the consumer localize.
        raw = (node.get("startDate") or "").strip()
        parsed = stamp(raw)
        if parsed is None:
            m = re.match(r"\w{3} (\w{3}) (\d{1,2}) (\d{4}) (\d{2}):(\d{2})", raw)
            if not m:
                continue
            month = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"].index(m.group(1)) + 1
            parsed = datetime(int(m.group(3)), month, int(m.group(2)),
                              int(m.group(4)), int(m.group(5))).isoformat() + "+00:00"
        loc = node.get("location")
        venue = loc.get("name") if isinstance(loc, dict) else loc
        add(node.get("name"), parsed, venue, node.get("url"))

# --- shape 2: schedule rows (promoter / venue pages) ------------------------
YEAR = datetime.now().year
for row in re.split(r'class="schedule-row', src)[1:]:
    link = re.search(r'<a href="(/cs/[^"]+)"[^>]*title="([^"]+)"', row)
    when = re.search(r"\b\w{2,3}\s+(\d{1,2})\.\s*(\d{1,2})\.(?:\s*(\d{4}))?\s+(\d{1,2}):(\d{2})", html.unescape(row))
    if not (link and when):
        continue
    day, month, year, hour, minute = when.groups()
    year = int(year) if year else YEAR
    # A listing only ever shows what is still ahead, so a month already behind
    # us belongs to next year.
    if year == YEAR and int(month) < datetime.now().month:
        year += 1
    venue = re.search(r'class="[^"]*venue[^"]*"[^>]*>([^<]{2,80})<', row)
    add(html.unescape(link.group(2)),
        prague_parts(year, int(month), int(day), int(hour), int(minute)),
        html.unescape(venue.group(1)).strip() if venue else None,
        "https://goout.net" + link.group(1))

print(json.dumps(items, ensure_ascii=False))
PY
