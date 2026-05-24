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
    {"title": "Mahler 5 — Česká filharmonie / Bychkov",
     "ensemble": "Česká filharmonie",
     "venue": "Rudolfinum",
     "starts_at": "2026-06-12T19:30:00+02:00",
     "date_human": "Čt 12. 6. 2026, 19:30",
     "url": "https://...",
     "price_czk": "1 200–2 900",
     "tickets_available": true,
     "program": [
       {"composer": "Gustav Mahler", "work": "Symfonie č. 5 cis moll"}
     ],
     "soloists": [],
     "conductor": "Semyon Bychkov",
     "score": 0.92,
     "season_event": false,
     "why_cs": "Mahler 5 — Mahlera máš 6× v Discogs kolekci. ČF (36×) je tvůj nejzastoupenější orchestr; Bychkov je jediný šéfdirigent ČF, kterého ještě nesahal jsi naživo."}
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

`why_cs` is mandatory and must be specific. **Lead with composers + works**, not
conductors. Petr's primary signal is "I want to hear Shostakovich", not "I want
to see Conductor X". Reference Discogs counts by composer where possible.
Generic blurbs ("zajímavá hudba!") are forbidden.

`program` is an array of `{composer, work}` pairs and is the most important
ranking input. Fill it from the venue's event detail page (step 5d). If the
detail page lookup failed, leave `program: []` and surface
`MISSING_PROGRAM=<event_url>` in the run log.

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

### 2. Resolve Discogs API key (optional)

```bash
DISCOGS_TOKEN="$(op item get 'Discogs API key' --fields label=credential --reveal 2>/dev/null || true)"
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
DISCOGS_USERNAME=$(awk '/^## Discogs username/{flag=1; next} flag && NF{print; exit}' \
  "$SKILL_DIR/preferences.md")
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

Use Python for date math — BSD `date` on macOS lacks `-d` and `-Iseconds`,
so `date -d '+28 days' -Iseconds` silently produces garbage there.

```bash
NOW=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds'))")
HORIZON=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc).astimezone()+timedelta(days=28)).isoformat(timespec='seconds'))")
CANDIDATES=$(echo "$CANDIDATES" | jq --arg now "$NOW" --arg h "$HORIZON" \
  '[.[] | select(.starts_at >= $now and .starts_at <= $h)]')
```

#### 5d. Enrich top candidates with program detail (composers + works)

Petr ranks by composer + work, not conductor. The scraper / festival `title`
is almost always a marketing string ("LSO • Pappano") that hides the actual
program. Before ranking, fetch each candidate's detail page via WebFetch and
extract the program into `{composer, work}` pairs.

Cap at the top 30 candidates by simple pre-rank (ensemble bias + date
proximity) to keep WebFetch usage bounded.

For each surviving candidate, call WebFetch with this prompt:

> "Extract the concert program as JSON: `{program: [{composer, work}],
> soloists: [], conductor: '...' or null, price_czk: '...' or null,
> tickets_available: true|false|null}`.
> List every composer + work that will be performed. For `tickets_available`:
> `true` if a 'Koupit lístek' / 'Buy ticket' / cart button is present,
> `false` if the page says 'Vyprodáno' / 'Sold out' / 'Nedostupné' or
> equivalent, `null` if you can't tell. For `price_czk` give a range
> like '500–1 500' if multiple price categories, single number otherwise.
> Output JSON only."

Merge the returned `program` / `soloists` / `conductor` / `price_czk` /
`tickets_available` back onto the candidate. If WebFetch fails or the
prompt returns no program, set `program: []` and log
`MISSING_PROGRAM=<url>` — that candidate ranks lower because the LLM
can't justify it via composer overlap.

**Don't drop sold-out candidates.** Petr sometimes catches released seats
via a watchdog (hlídací pes na sreality of cultural tickets). Keep them
in the pool with `tickets_available: false`; the ranking step adds a flag
to `why_cs` so the email surfaces it.

### 6. Exclude already-booked

Use UTC `Z` for the API datetime parameters and `--data-urlencode` — the
KP backend strict-parses ISO8601, and the `+` in `+02:00` is silently turned
into a space by curl's URL handling, which makes the validator reject it.

```bash
NOW_UTC=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
HORIZON_PLUS=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(days=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
BOOKED_TITLES=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  --data-urlencode "starts_from=$NOW_UTC" \
  --data-urlencode "starts_to=$HORIZON_PLUS" \
  --data-urlencode "category=concert" \
  --data-urlencode "limit=200" \
  -G "$KP_API_BASE/v1/events" \
  | jq -r '.items[].title // empty')
# Drop candidates whose title fuzzy-matches a booked one.
# (The LLM does the fuzzy match in step 7; just pass $BOOKED_TITLES along.)
```

### 7. Rank candidates (LLM step — you, the skill runner, ARE the LLM)

Reason over:

- `$PREFS` — vetoes, weights, favourite ensembles, soloists
- `$SPOTIFY_TASTE` — fresh artists/albums
- `$DISCOGS_TASTE` — owned-record artists, **counted by occurrence** (e.g.
  "Beethoven 13×, Šostakovič 7×") — this is the primary composer signal
- `$CANDIDATES` — every upcoming event, enriched by step 5d with `program`
- `$BOOKED_TITLES` — exclude duplicates

Pick **8–12** ranked candidates. Per item:

- **Composer overlap with Discogs is the PRIMARY signal.** Sum the Discogs
  occurrence counts for every composer in `program[]`. A concert with two
  composers Petr owns heavily (e.g. Šostakovič 7× + Bruckner 6× = 13) beats
  a "prestige" name + ensemble combo with no composer match. Do not lead
  with conductor fame; Petr wants to hear *the music*, not see *the maestro*.
- Ensemble and conductor are SECONDARY (used as tiebreakers, e.g. ČF (36×)
  vs. a touring orchestra he doesn't know).
- Apply genre weights from preferences (symfonická 1.0, komorní 1.0,
  vokální 0.9, soudobá 0.9, baroko 0.8, jazz s klasikou 0.7, world 0.4).
- Apply venue/ensemble bias from preferences as a small multiplier
  (~ +0.05 for a favourite ensemble).
- **Price deflator.** Read the thresholds from preferences.md `## Price
  awareness`. Compute an **effective midpoint** of the `price_czk` range
  with a VIP-aware clamp (Pražské jaro at Obecní dům, Forum Karlín big
  nights and similar venues sell 4 000–8 000 Kč box / sponsor seats that
  skew the midpoint up past parter reality):

  ```python
  # price_czk parsed into (lower, upper) ints
  if lower > 0 and upper / lower > 5:
      effective_upper = lower * 4          # VIP-skewed → ignore the top tier
  else:
      effective_upper = upper
  midpoint = (lower + effective_upper) / 2
  ```

  Then subtract the configured penalty (default: 0 below 1 000 Kč, –0.05
  between 1 000–2 000, –0.15 between 2 000–3 000, exclude > 3 000 Kč
  entirely). Surface the clamp visibly in run logs (e.g.
  `PRICE_CLAMP=Rotterdam 900–8000 → 900–3600 mid 2250`) so it's auditable.
- **Sold-out handling.** Keep `tickets_available: false` candidates in
  the pool. Don't deflate their score for it — the watchdog might catch
  released seats. Instead, prepend "⚠ Lístky momentálně vyprodány — můžeš
  zkusit hlídacího psa. " to `why_cs`.
- Mark 1–2 items `season_event: true` if they're genuinely once-a-season
  (Vienna Phil visiting, last tour of a soloist Petr follows, world premiere
  by a composer in collection).
- Write a Czech `why_cs` that **leads with composer + work**, then names the
  specific Discogs count or genre weight that justifies it. Conductor goes
  last, if at all.

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
