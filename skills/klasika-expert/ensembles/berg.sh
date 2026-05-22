#!/usr/bin/env bash
# Scrapes upcoming concerts from berg.cz (Orchestr Berg — kontemporární
# hudba). Their CMS is ancient and serves cp1250 plain text without semantic
# markup, but the detail pages have a consistent URL pattern: YYMMDD.html
# (or YYMMDD_slug.html). We pull dates from the URL itself + scrape the
# homepage for the title text that appears next to each link.

set -u

URL="https://www.berg.cz"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="Orchestr Berg"

TMP=$(mktemp -t berg-XXXXXX.html)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 30 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, html, json
from datetime import date, datetime

src = open(os.environ["HTML_PATH"], encoding="cp1250", errors="replace").read()
ensemble = os.environ["ENSEMBLE"]

# Find every YYMMDD.html href (optionally with _suffix). The date prefix is
# the canonical event id; downstream we'll fetch the detail page for the
# title only if/when we need a richer blurb.
hrefs = re.findall(r'href="((\d{6})(?:_[a-z]+)?\.html)"', src)
items = []
seen = set()
today = date.today()

# Strip scripts/tags to get a plain-text view for title lookup
plain = re.sub(r'<script[^>]*>.*?</script>', '', src, flags=re.DOTALL)
plain = re.sub(r'<[^>]+>', ' ', plain)
plain = html.unescape(plain)
plain = re.sub(r'&nbsp;', ' ', plain)
plain = re.sub(r'\s+', ' ', plain)

for href, ymd in hrefs:
    if href in seen:
        continue
    seen.add(href)

    try:
        yr = 2000 + int(ymd[0:2])
        mo = int(ymd[2:4])
        day = int(ymd[4:6])
        when = date(yr, mo, day)
    except ValueError:
        continue
    if when < today:                                      # past concert
        continue

    # Find the title text that appears immediately before the date in plain
    # text. Berg formats it as "TITLE pondělí 1. června 2026, 19:30 | venue".
    # We search for the date words in plain text and take the 80 chars before.
    cz_months = {1:"ledna",2:"února",3:"března",4:"dubna",5:"května",6:"června",
                 7:"července",8:"srpna",9:"září",10:"října",11:"listopadu",12:"prosince"}
    needle = rf'\b{day}\.\s*{cz_months[mo]}\s*{yr}\b'
    m = re.search(needle, plain)
    title = None
    if m:
        before = plain[max(0, m.start()-120):m.start()].rstrip()
        # Title is the CAPS-ish phrase at the end. Look for last sequence of
        # ALLCAPS/Capitalized words.
        tm = re.search(r'([A-ZÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ&]{2,}[\w\s\-&,áčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ\.]{3,80})\s*$', before)
        if tm:
            title = tm.group(1).strip().title()
    if not title:
        # Fallback: use the URL slug suffix if present, otherwise placeholder
        slug_m = re.match(r'\d{6}(?:_([a-z]+))?\.html', href)
        title = (slug_m.group(1).replace('_',' ').title() if slug_m and slug_m.group(1)
                 else f"Berg / {when.strftime('%-d. %-m. %Y')}")

    # Berg concerts default to 19:30 — the homepage usually says so but we
    # don't parse the time precisely.
    items.append({
        "ensemble": ensemble,
        "venue": None,
        "title": title,
        "starts_at": f"{yr:04d}-{mo:02d}-{day:02d}T19:30:00+02:00",
        "artists": [ensemble],
        "url": f"https://www.berg.cz/{href}",
        "price_czk": None,
    })

print(json.dumps(items, ensure_ascii=False))
PY
