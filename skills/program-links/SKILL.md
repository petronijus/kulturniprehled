---
name: program-links
description: Resolves where to listen to every piece in the Kulturní Přehled season pool — searches Spotify (Web API, refresh token from 1Password) for the works named in candidates' programmes and pushes the links to the KP API, so the planner's ▶ buttons play a real recording instead of a search. Sends no email, changes no plan. Local-only — needs `op` and a season:write PAT. Trigger phrases - "dohledej odkazy na skladby", "program links", "spotify odkazy do planneru", "resolve programme links".
---

## Task

Every candidate in the season pool carries a `program` — the works it
plays. The planner renders one ▶ per piece; without a resolved link that
▶ is only a Spotify search. This skill turns the searches into real
recordings, once per piece for the whole season.

Two properties make it cheap to re-run: the API stores links **per piece**
(folded `author|work`), not per candidate — Dvořák's Ninth is resolved once
even when four orchestras play it — and the upsert is **additive per
service**, so a run that only finds Spotify never drops an existing YouTube
link.

**Never invent a URL.** Every link must come from a Spotify API response
(or a search result you actually opened). A plausible-looking
`open.spotify.com/album/<made up>` is worse than no link — the ▶ silently
leads nowhere and nobody notices for months.

### Prerequisites

- `op` signed in — 1Password item `Spotify API key` (fields: `client ID`,
  `client secret`, `refresh_token`), same item `/kulturni-prehled-ingest`
  uses for playlists.
- A KP token with `season:write` (the local unrestricted PAT qualifies).
- Local only: the cloud routine never runs this.

### 1. Read what needs resolving

```bash
KP_API_BASE=${KP_API_BASE:-https://kulturniprehled.example.com}
KP_TOKEN=$(op-cache "kulturni-prehled api-token" credential)
AUTH="Authorization: Bearer $KP_TOKEN"
UA="kp-skill/1.0"                     # Cloudflare blocks the default UA

SEASON_UUID=$(curl -sS -A "$UA" -H "$AUTH" "$KP_API_BASE/v1/season/plans/current" | jq -r .id)

# The pool, paged (limit is capped at 1000).
curl -sS -A "$UA" -H "$AUTH" \
  "$KP_API_BASE/v1/season/plans/$SEASON_UUID/pool?limit=1000&offset=0" > /tmp/kp-pool.json

# Already-resolved pieces.
curl -sS -A "$UA" -H "$AUTH" "$KP_API_BASE/v1/season/program-links" > /tmp/kp-links.json
```

### 2. Fold the programmes into distinct pieces

The key **must** match the server's (`kp_api/domain/program_key.py`) or the
planner looks up links stored under a different key. Same recipe, inline:

```python
import json, re, unicodedata

NON_ALNUM = re.compile(r"[^a-z0-9]+")

def fold(text):
    decomposed = unicodedata.normalize("NFKD", (text or "").lower())
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return NON_ALNUM.sub(" ", stripped).strip()

def key(author, work):
    k = f"{fold(author)}|{fold(work)}"
    return None if k == "|" else k

pool = json.load(open("/tmp/kp-pool.json"))["items"]
have = {i["key"]: i for i in json.load(open("/tmp/kp-links.json"))["items"]}

pieces = {}
for candidate in pool:
    for entry in candidate.get("program") or []:
        author = entry.get("composer") or entry.get("author") or entry.get("director")
        work = entry.get("work") or entry.get("play") or entry.get("film")
        k = key(author, work)
        if k is None or (k in have and have[k].get("spotify_url")):
            continue
        # Keep the richest spelling seen and the lane, which decides where
        # to look: klasika/elektronika → Spotify, divadlo/film → YouTube.
        pieces.setdefault(k, {"author": author, "work": work, "lanes": set()})
        pieces[k]["lanes"].add(candidate["lane"])
```

Report the count before searching (`N pieces to resolve, M already
linked`). A season's first run is typically 150–400 pieces; later runs are
a handful.

### 3. Spotify token

```bash
SP_CLIENT_ID=$(op item get 'Spotify API key' --fields 'label=client ID' --reveal)
SP_CLIENT_SECRET=$(op item get 'Spotify API key' --fields 'label=client secret' --reveal)
SP_REFRESH=$(op item get 'Spotify API key' --fields label=refresh_token --reveal)
SP_TOKEN=$(curl -sS -X POST https://accounts.spotify.com/api/token \
  -u "$SP_CLIENT_ID:$SP_CLIENT_SECRET" \
  -d grant_type=refresh_token -d refresh_token="$SP_REFRESH" | jq -r .access_token)
[ -n "$SP_TOKEN" ] && [ "$SP_TOKEN" != "null" ] || { echo "spotify auth failed"; exit 1; }
```

Never echo any of these. `op item get` straight into the variable, nothing
else — the tokens must not reach the transcript.

### 4. Search — you are the curator

For each piece (klasika / elektronika lanes):

```bash
curl -sS -H "Authorization: Bearer $SP_TOKEN" -G 'https://api.spotify.com/v1/search' \
  --data-urlencode "q=Antonín Dvořák Symfonie č. 9" \
  --data-urlencode 'type=album' --data-urlencode 'limit=5'
```

Czech titles are the scrape's language, Spotify's catalogue mostly is not:
search the **international** form of the work when the Czech one misses
("Symfonie č. 9 → Symphony No. 9", "Prodaná nevěsta → The Bartered
Bride"). One retry with the translated query is worth it; a third is not.

Pick with the same priority the ingest skill uses for playlists:

1. a recording by the performers the candidate lists (check `detail` —
   conductor/soloist), which is the closest thing to the concert;
2. else a canonical, well-regarded recording (a named conductor/orchestra,
   a complete recording rather than a single movement);
3. else the top hit — but only if it plausibly *is* the work. A compilation
   called "Classical Relaxation" containing one movement is a miss, not a
   third-best answer: leave the piece unresolved instead.

Take the album URL from `external_urls.spotify` in the response (never
build it by hand) and set `match_label` to `"<artist> — <album>"` so a
wrong pick is visible in the planner tooltip without opening it.

For divadlo / film pieces Spotify is the wrong catalogue: skip it and, if
you can find one cheaply, use WebSearch for a YouTube trailer or a
production video, taking the URL from the result. Never guess a video id.

### 5. Push

```bash
# items: [{author, work, spotify_url?, youtube_url?, match_label?}], ≤500 per call
curl -sS -A "$UA" -X PUT -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"items\": $CHUNK}" "$KP_API_BASE/v1/season/program-links"
```

The response counts `created` / `updated` / `unchanged` / `skipped`.
`skipped` > 0 means entries arrived with no identity or no link at all —
those are bugs in step 2/4, worth naming in the report.

### 6. Report (Czech)

- how many pieces were resolved this run, how many the season now covers;
- the pieces you deliberately left unresolved and why (no catalogue entry,
  only dubious compilations);
- anything that looked like a scrape problem — a "programme" that is really
  a marketing sentence tends to surface here first.

## Notes

- **Re-runnable anytime.** Identical pushes report `unchanged`; new pieces
  appear as the weekly `/kulturni-prehled` watcher tops the pool up.
- **Non-fatal per piece.** A search that fails or returns nothing leaves
  that piece without a link; the planner still offers a Spotify search. One
  bad piece never aborts the run.
- **Plan-neutral.** This skill never touches `plan_status`, candidates or
  scenarios — only the piece→link map.
- Run it after `/kulturni-sezona` (the season scrape fills the pool) and
  occasionally after a few weekly runs have added novelties.
