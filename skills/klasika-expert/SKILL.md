---
name: klasika-expert
description: Domain-expert agent for vážná hudba (klasika + soudobá vážná + jazz s klasickým přesahem). Pulls Petr's Spotify classical/jazz taste + Discogs collection + hand-edited preferences, scrapes upcoming concerts of the favourite Prague orchestras via static scrapers, hits a list of festival URLs via WebFetch, and produces a ranked top-N list of candidates as structured JSON. **Sends no email — output is consumed by the kulturni-prehled aggregator.** Can also be invoked directly when the user wants a klasika snapshot in chat.
---

## Task

Build a ranked list of upcoming **vážná hudba** events Petr should
consider this week. Write the result as JSON to a known location;
**never send email**. The `kulturni-prehled` aggregator picks up the
file, merges with other experts, applies cross-domain rules
(balance, spacing, "udalost sezony" exceptions), and sends one
combined email.

### 0. Output contract — write this file at the end

```
/tmp/kp-digest-CW<n>/klasika.json
```

`<n>` = ISO week number, from `date +%V`. The aggregator looks here
after invoking the expert and refuses to send anything if the file
is missing or malformed.

The JSON shape:

```json
{
  "lane": "klasika",
  "label": "Vážná hudba",
  "generated_at": "2026-05-22T19:00:00+02:00",
  "missing_sources": ["discogs"],
  "items": [
    {"title": "Česká filharmonie / Bychkov / Mahler 5",
     "ensemble": "Česká filharmonie",
     "venue": "Rudolfinum",
     "starts_at": "2026-06-12T19:30:00+02:00",
     "date_human": "Čt 12. 6. 2026, 19:30",
     "url": "https://...",
     "price_czk": 1500,
     "score": 0.92,
     "season_event": false,
     "why_cs": "Máš Mahlera v kolekci (Sym 2 / Abbado) a Bychkov je jediný šéfdirigent ČF, kterého ještě nesahal jsi naživo."}
  ]
}
```

Pick **8–12 candidates**, not 5 — the aggregator will trim down to ~2
when it applies spacing rules across all lanes. Be generous.

`score` is 0.0–1.0. Don't agonise over absolute calibration; use it
to express relative ranking within this lane.

`season_event: true` for the 1–2 picks that are genuinely
once-a-season material (Vienna Phil visiting, world premiere by a
composer Petr loves, soloist near retirement). The aggregator will
allow these to break the 1-event-per-week spacing rule.

`why_cs` is mandatory and must be specific. Reference Discogs/Spotify
artists by name where possible. Generic blurbs ("zajímavá hudba!")
are forbidden.

### 1. Resolve KP API base + bearer token

```bash
KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.example.com}"
KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --fields label=credential --reveal 2>/dev/null)"
if [ -z "$KP_TOKEN" ]; then
  set -a; . ~/Documents/Dev/kulturniprehled/.env 2>/dev/null; set +a
  KP_TOKEN="${KP_API_TOKEN:-}"
fi
[ -n "$KP_TOKEN" ] || { echo "no Kulturní Přehled token available"; exit 1; }
```

**Cloudflare WAF gotcha** — every `curl` to `$KP_API_BASE` must pass
`-A 'kp-skill/1.0'` (default curl UA returns 403 error 1010).

### 2. Resolve Discogs PAT (optional)

```bash
DISCOGS_TOKEN="$(op item get 'Discogs PAT' --fields label=credential --reveal 2>/dev/null || true)"
```

Empty token is **not fatal** — the Discogs step (4b) skips itself and
the ranking runs with Spotify + preferences only. Record
`MISSING_DISCOGS=1` and surface it in the output JSON's
`missing_sources`.

### 3. Load preferences

```bash
SKILL_DIR=~/Documents/Dev/kulturniprehled/skills/klasika-expert
PREFS=$(cat "$SKILL_DIR/preferences.md")
ENSEMBLE_SCRAPERS=$(grep -A40 'Active ensemble scrapers' "$SKILL_DIR/preferences.md" \
  | sed -n 's/^- *//p' | awk '{print $1}')
WEBFETCH_URLS=$(grep -A40 'Active festival WebFetch URLs' "$SKILL_DIR/preferences.md" \
  | sed -n 's/^- *\(https\?:\/\/[^ ]\+\).*/\1/p')
DISCOGS_USERNAME=$(grep -A1 'Discogs username' "$SKILL_DIR/preferences.md" \
  | tail -1 | tr -d ' ')
```

### 4. Gather taste inputs

#### 4a. Spotify

Call `mcp__claude_ai_Spotify__search` with `language: "en"`:

- `"my classical / contemporary / chamber music top artists last 12 months"`
- `"my saved classical albums recently"`

Collect artist + album names into `$SPOTIFY_TASTE`. If the MCP returns
nothing, set `MISSING_SPOTIFY=1`.

#### 4b. Discogs (if token present)

```bash
ARTISTS=""
PAGE=1
while :; do
  RESP=$(curl -sS -H "Authorization: Discogs token=$DISCOGS_TOKEN" -A 'kp-skill/1.0' \
    "https://api.discogs.com/users/$DISCOGS_USERNAME/collection/folders/0/releases?per_page=100&page=$PAGE")
  COUNT=$(echo "$RESP" | jq '.releases | length')
  [ "$COUNT" -eq 0 ] && break
  PAGE_ARTISTS=$(echo "$RESP" | jq -r '.releases[].basic_information.artists[].name' \
    | sed 's/[ ]*([0-9]\+)$//')      # strip "(2)" disambiguators
  ARTISTS=$(printf '%s\n%s' "$ARTISTS" "$PAGE_ARTISTS")
  NEXT=$(echo "$RESP" | jq -r '.pagination.urls.next // empty')
  [ -z "$NEXT" ] && break
  PAGE=$((PAGE + 1))
  sleep 1                            # 60 req/min cap for authed users
done
DISCOGS_TASTE=$(echo "$ARTISTS" | sort -u | sed '/^$/d')
```

### 5. Gather candidate events

#### 5a. Run ensemble scrapers (static, fast)

```bash
CANDIDATES='[]'
for E in $ENSEMBLE_SCRAPERS; do
  SCRAPER="$SKILL_DIR/ensembles/$E.sh"
  if [ ! -x "$SCRAPER" ]; then
    echo "WARN: scraper '$E' missing"; continue
  fi
  OUT=$("$SCRAPER" 2>/tmp/kp-klasika-$E.err)
  if [ -z "$OUT" ] || ! echo "$OUT" | jq -e . >/dev/null 2>&1; then
    echo "WARN: '$E' returned nothing parseable — likely HTML changed"
    continue
  fi
  CANDIDATES=$(jq -n --argjson a "$CANDIDATES" --argjson b "$OUT" '$a + $b')
done
```

#### 5b. WebFetch festival URLs (dynamic)

For each URL in `$WEBFETCH_URLS`, use the **WebFetch** tool with this
extraction prompt:

> "List every upcoming classical / contemporary classical / jazz event
> on this page in the next 4 weeks from today, as a JSON array. Each
> item: `title`, `starts_at` (ISO 8601), `venue`, `url` (absolute,
> deduplicated), `price_czk` if mentioned. Skip events already past.
> Skip duplicates. Output JSON only."

Append the LLM's JSON to `$CANDIDATES`. On WebFetch failure: log
`WARN: WebFetch <url> failed` and continue.

#### 5c. Filter to the 4-week horizon

```bash
NOW=$(date -Iseconds)
HORIZON=$(date -d '+28 days' -Iseconds)
CANDIDATES=$(echo "$CANDIDATES" | jq --arg now "$NOW" --arg h "$HORIZON" \
  '[.[] | select(.starts_at >= $now and .starts_at <= $h)]')
```

### 6. Exclude already-booked

```bash
HORIZON_PLUS=$(date -d '+60 days' -Iseconds)
BOOKED_TITLES=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  "$KP_API_BASE/v1/events?starts_from=$NOW&starts_to=$HORIZON_PLUS&category=concert&limit=200" \
  | jq -r '.items[].title // empty')
# Drop candidates whose title fuzzy-matches a booked one.
# (The LLM does the fuzzy match in step 7; just pass $BOOKED_TITLES along.)
```

### 7. Rank candidates (LLM step — you, the skill runner, ARE the LLM)

Reason over:

- `$PREFS` — vetoes, weights, favourite ensembles, soloists
- `$SPOTIFY_TASTE` — fresh artists/albums
- `$DISCOGS_TASTE` — owned-record artists
- `$CANDIDATES` — every upcoming event from scrapers + WebFetch
- `$BOOKED_TITLES` — exclude duplicates

Pick **8–12** ranked candidates. Per item:

- Match against Discogs/Spotify artists by name; assign higher score
  when there's a concrete overlap
- Apply genre weights from preferences
- Apply venue/ensemble bias from preferences
- Mark 1–2 items `season_event: true` if they're genuinely
  once-a-season (Vienna Phil visiting, last tour of a soloist Petr
  follows, world premiere by a composer in collection)
- Write a Czech `why_cs` blurb that names a specific reason

### 8. Write output JSON

```bash
WEEK=$(date +%V)
DIGEST_DIR=/tmp/kp-digest-CW${WEEK}
mkdir -p "$DIGEST_DIR"
# Construct the output object inline from the ranked list you just produced.
# Use jq to build it cleanly; never write the file via echo if it could be
# parsed as a heredoc misuse.
cat > "$DIGEST_DIR/klasika.json" <<EOF
{
  "lane": "klasika",
  "label": "Vážná hudba",
  "generated_at": "$(date -Iseconds)",
  "missing_sources": [$MISSING_SOURCES_JSON],
  "items": $RANKED_ITEMS_JSON
}
EOF
```

Validate before exiting:

```bash
jq -e '.items | length >= 0' "$DIGEST_DIR/klasika.json" >/dev/null \
  || { echo "ERROR: klasika.json is malformed"; exit 1; }
```

### 9. Report back

Print a short Czech summary to stdout (the aggregator ignores it; it's
for when Petr runs the skill standalone):

> Klasika: {{count}} kandidátů ($DIGEST_DIR/klasika.json).
> Zdroje: {{sources_used}}. Chybělo: {{missing_sources}}.

## When to use this skill

- Indirectly: every Monday via the `/kulturni-prehled` aggregator
  (registered with `/schedule`).
- Directly: `/klasika-expert` whenever Petr wants a klasika-only
  snapshot in chat without spamming his inbox.

## When NOT to use this skill

- Don't run more than once per day — Discogs rate-limits authed users
  to 60 req/min, and the venue scrapers + WebFetch hit external sites
  politely.
- Don't try to send email from this skill — that's the aggregator's
  exclusive responsibility.
