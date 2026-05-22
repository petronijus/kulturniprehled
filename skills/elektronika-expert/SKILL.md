---
name: elektronika-expert
description: Domain-expert agent for elektronická hudba (experimental, IDM, techno, ambient, dub, modular, live electronics). Pulls Petr's Spotify electronic library + hand-edited preferences, hits a list of club/festival URLs via WebFetch (electronica scene is too dynamic for static scrapers), and produces a ranked top-N list of candidates as structured JSON. **Sends no email — output is consumed by the kulturni-prehled aggregator.** Can also be invoked directly when the user wants an electronica snapshot in chat.
---

## Task

Build a ranked list of upcoming **elektronická hudba** events Petr
should consider this week. Write the result as JSON to a known
location; **never send email**. The `kulturni-prehled` aggregator
picks up the file, merges with other experts, applies cross-domain
rules, and sends one combined email.

### 0. Output contract — write this file at the end

```
/tmp/kp-digest-CW<n>/elektronika.json
```

Same shape as `klasika.json` (see `skills/klasika-expert/SKILL.md`
step 0 for the schema). The only differences:

- `lane`: `"elektronika"`
- `label`: `"Elektronika"`
- `ensemble`: usually `null` (electronica events are typically
  artist/DJ-led, no "ensemble"); use `null` in the JSON output
- The aggregator handles spacing across both lanes — the elektronika
  expert just emits its own candidates without worrying about clashes
  with klasika picks.

Pick **8–12 candidates**; the aggregator trims. Mark 1–2 items
`season_event: true` if genuinely once-a-tour (Aphex Twin live,
Autechre live, Boiler Room special, etc.).

### 1. Resolve KP API base + bearer token

```bash
KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.example.com}"
KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --fields label=credential --reveal 2>/dev/null)"
if [ -z "$KP_TOKEN" ]; then
  set -a; . ~/Documents/Dev/kulturniprehled/.env 2>/dev/null; set +a
  KP_TOKEN="${KP_API_TOKEN:-}"
fi
[ -n "$KP_TOKEN" ] || { echo "no KP token"; exit 1; }
```

**Cloudflare WAF gotcha** — every `curl` to `$KP_API_BASE` passes
`-A 'kp-skill/1.0'`.

### 2. Load preferences

```bash
SKILL_DIR=~/Documents/Dev/kulturniprehled/skills/elektronika-expert
PREFS=$(cat "$SKILL_DIR/preferences.md")
WEBFETCH_URLS=$(grep -A40 'Active venue / festival WebFetch URLs' "$SKILL_DIR/preferences.md" \
  | sed -n 's/^- *\(https\?:\/\/[^ ]\+\).*/\1/p')
```

(No ensemble scrapers; electronica relies entirely on WebFetch.)

### 3. Spotify taste

Call `mcp__claude_ai_Spotify__search` with `language: "en"`:

- `"my electronic / techno / ambient / IDM top artists last 12 months"`
- `"my saved electronic albums recently"`

Collect into `$SPOTIFY_TASTE`. On miss: `MISSING_SPOTIFY=1`.

(No Discogs step — Petr's Discogs is biased toward classical/jazz,
so it's less useful for electronica.)

### 4. Gather candidates via WebFetch

For each URL in `$WEBFETCH_URLS`, use **WebFetch** with this prompt:

> "List every upcoming electronic / techno / ambient / experimental
> / IDM / live electronics event on this page in the next 4 weeks,
> as a JSON array. Each item: `title`, `starts_at` (ISO 8601),
> `venue`, `url` (absolute, deduplicated), `price_czk` if mentioned.
> Skip past events. Skip non-music. Output JSON only."

Append to `$CANDIDATES`. On failure: log warning, continue.

```bash
NOW=$(date -Iseconds)
HORIZON=$(date -d '+28 days' -Iseconds)
CANDIDATES=$(echo "$CANDIDATES" | jq --arg now "$NOW" --arg h "$HORIZON" \
  '[.[] | select(.starts_at >= $now and .starts_at <= $h)]')
```

### 5. Exclude already-booked

```bash
HORIZON_PLUS=$(date -d '+60 days' -Iseconds)
BOOKED_TITLES=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  "$KP_API_BASE/v1/events?starts_from=$NOW&starts_to=$HORIZON_PLUS&category=concert&limit=200" \
  | jq -r '.items[].title // empty')
```

(Yes, `category=concert` for electronica too — the KP schema doesn't
distinguish classical from electronica concerts.)

### 6. Rank candidates (LLM step — you are the LLM)

Reason over `$PREFS`, `$SPOTIFY_TASTE`, `$CANDIDATES`, `$BOOKED_TITLES`.
Pick **8–12** ranked. Write Czech `why_cs` blurbs that name a specific
reason (artist Petr follows on Spotify, label preference, "už dlouho
nic na Akropoli"). Mark 1–2 `season_event: true` if exceptional.

### 7. Write output JSON

```bash
WEEK=$(date +%V)
DIGEST_DIR=/tmp/kp-digest-CW${WEEK}
mkdir -p "$DIGEST_DIR"
cat > "$DIGEST_DIR/elektronika.json" <<EOF
{
  "lane": "elektronika",
  "label": "Elektronika",
  "generated_at": "$(date -Iseconds)",
  "missing_sources": [$MISSING_SOURCES_JSON],
  "items": $RANKED_ITEMS_JSON
}
EOF
jq -e '.items | length >= 0' "$DIGEST_DIR/elektronika.json" >/dev/null \
  || { echo "ERROR: elektronika.json malformed"; exit 1; }
```

### 8. Report back

> Elektronika: {{count}} kandidátů ($DIGEST_DIR/elektronika.json).
> Zdroje: {{sources_used}}. Chybělo: {{missing_sources}}.

## When to use

- Indirectly: every Monday via `/kulturni-prehled` (scheduled).
- Directly: `/elektronika-expert` for a chat snapshot.

## When NOT to use

- Don't send email from this skill — that's the aggregator's job.
