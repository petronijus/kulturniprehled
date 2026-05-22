#!/usr/bin/env bash
# Scrapes upcoming concerts from fok.cz/cs/program (Symfonický orchestr
# hl. m. Prahy FOK). Cards are `class="Program-item ..."` with a clean
# `<time datetime>` and a first-text-snippet title after the `</picture>`.

set -u

URL="https://www.fok.cz/cs/program"
UA='Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)'
ENSEMBLE_NAME="FOK – Symfonický orchestr hl. m. Prahy"

TMP=$(mktemp -t fok-XXXXXX.html)
trap 'rm -f "$TMP"' EXIT
curl -sS -L -A "$UA" --max-time 30 -o "$TMP" "$URL" 2>/dev/null || { echo '[]'; exit 0; }
[ ! -s "$TMP" ] && { echo '[]'; exit 0; }

HTML_PATH="$TMP" ENSEMBLE="$ENSEMBLE_NAME" python3 - <<'PY'
import os, re, html, json
src = open(os.environ["HTML_PATH"], encoding="utf-8").read()
ensemble = os.environ["ENSEMBLE"]

cards = re.split(r'<[^>]+class="Program-item\s', src)
items = []
seen = set()

for c in cards[1:]:
    h_m = re.search(r'<a href="(/[^"]+)">', c)
    t_m = re.search(r'<time datetime="([^"]+)"', c)
    if not (h_m and t_m):
        continue

    href = h_m.group(1)
    if href in seen:
        continue
    seen.add(href)

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

    items.append({
        "ensemble": ensemble,
        "venue": None,
        "title": title,
        "starts_at": t_m.group(1),
        "artists": [ensemble],
        "url": "https://www.fok.cz" + href,
        "price_czk": None,
    })

print(json.dumps(items, ensure_ascii=False))
PY
