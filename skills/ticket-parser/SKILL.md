---
name: kulturni-prehled-ingest
description: Processes downloaded cultural-event tickets — registers the event with cover/venue images and price in the Kulturní Přehled backend, builds a Spotify concert playlist (concerts only), then mirrors the event into the shared Google Calendar and uploads tickets to Google Drive. Běla gets notified automatically via the mobile app's background sync.
---

## Task

The user has just downloaded ticket(s) for a concert, theatre play or cinema
screening. Run the steps below — parallelize where the order does not
matter — and report a short Czech summary at the end.

The Kulturní Přehled backend is the source of truth for the shared agenda;
the Google steps remain for now to keep historical workflows alive.

### 1. Find the tickets

Run `ls -lt ~/Downloads/ | head -20`. From the most recent files pick the
one(s) that look like cultural-event tickets — typically PDFs with names
suggesting a ticket (e.g. `vstupenky`, `ticket`, `eTicket`, `listek`, a
festival name, etc.). One event can have multiple ticket files.

**Filename gotcha.** Some browsers save tickets with brackets in the name
(`[object Object]_5330.pdf`). `curl` interprets `[...]` as a glob range
and will refuse to upload — `cp` each affected file to `/tmp/<clean>.pdf`
first and feed the copy into steps 7 and 10 instead of the original.

### 2. Extract metadata from the tickets

Read each PDF and extract:

- **Title** — performer / play / film name
- **Category** — one of `concert`, `theatre`, `cinema`, `other`
  (classical/rock/jazz → `concert`, divadlo → `theatre`, kino →
  `cinema`, otherwise `other`)
- **Date and time (start)**, including timezone
- **Venue full address** as a single string (`street + house number +
  ZIP + city`) — this also drives the "Mapa" button on the mobile
  detail screen, which opens mapy.cz with that address pre-filled, so
  there's no separate map URL field to populate.
- **Seat info** (sector, row, seat numbers) — kept for the event
  description and the email.
- **Ticket price** in Kč — read from the PDF (e.g. `1690 Kč`). Convert
  to cents (`1690 * 100 = 169000`) for step 8. If the ticket shows the
  total only (festival packs), divide evenly by ticket count.

  **Foreign currency.** If the PDF only quotes a non-CZK price (e.g.
  Elbphilharmonie Hamburg tickets in EUR), convert at the **current
  ČNB daily fixing** before writing the cost row. Don't store the
  foreign amount as if it were Kč — it'd lie to the Stats screen.

  ```bash
  # ČNB daily fixing JSON. EUR row's `rate` is per 1 EUR (amount=1).
  # If the currency you need has amount=100 (e.g. JPY), divide rate/100.
  RATE=$(curl -fsS 'https://api.cnb.cz/cnbapi/exrates/daily?lang=EN' \
    | jq -r '.rates[] | select(.currencyCode=="EUR") | .rate / .amount')
  PRICE_EUR=98               # from the PDF
  PRICE_CZK=$(python3 -c "print(round($PRICE_EUR * $RATE))")
  PRICE_CENTS=$(( PRICE_CZK * 100 ))
  ```

  Mention the original amount + the rate in the cost-row `note`
  ("`2× 98 EUR @ CNB 24.325 CZK/EUR`") so the conversion stays
  auditable later.

### 3. Find the program + images (mandatory)

The mobile detail screen always wants three things populated. Treat all
three as required — if a search comes up empty, try one more angle
before giving up.

**Images are downloaded, resized, and re-hosted in our MinIO**
(`event-images` bucket, anonymous-read) — not hot-linked from
external sources. That gives:

- One canonical size + format regardless of the source (no Wikimedia
  thumb roulette, no broken links if a festival rotates posters);
- Festival-specific posters that beat a generic Wikipedia portrait
  (the artist is "Anoushka Shankar" but the visual that belongs on
  the agenda is the *Prague Sounds Anoushka Shankar* poster, not her
  press headshot);
- Predictable load times on the agenda.

The picker order for what to download:

- **`cover_image_url` source**
  1. Organizer event detail page — `<meta property="og:image">`,
     hero banner, large landscape photo of the performer. Right-click
     ↦ copy-image-link or scrape via WebFetch ("list every
     `https://` image URL on this page, especially the main hero").
  2. Artist official site (press / EPK / tour page).
  3. Wikipedia infobox photo (fallback, often less specific).
- **`venue_image_url` source**
  1. Venue's own site — header photo of the building.
  2. Wikipedia / Wikimedia Commons (Rudolfinum, Forum Karlín,
     Lucerna, etc.).
  3. Organizer page hero for festival sites (Letní Letná) without a
     single venue building.
- **Program / line-up** — organizer event page first, then any
  festival schedule. Capture conductor, soloists, work names, opening
  act. If genuinely not published, say so in the notes — do not
  invent.

Avoid image-search result pages, Google Image hotlinks, and JS-loaded
placeholders. The URL must return raw image bytes:

```bash
curl -fsS -A 'Mozilla/5.0' -o /tmp/cover_raw "$SOURCE_URL"
file /tmp/cover_raw   # expect "JPEG image data" or "PNG image data"
```

Then resize with Python Pillow (available on this machine; ImageMagick
isn't, don't shell out to `magick` / `convert`):

```bash
python3 - <<'PY'
from PIL import Image
src = Image.open("/tmp/cover_raw")
src.thumbnail((960, 960))                              # long-edge cap
src.convert("RGB").save(
    "/tmp/cover_960.jpg",
    "JPEG", quality=82, optimize=True, progressive=True,
)
PY
```

Target: long edge 960 px, JPEG quality 82, progressive. Usually
~80-300 KB. Larger source files shrink to fit; smaller files keep
their original dimensions. Then upload via the KP presigned PUT and
PATCH the event with the public URL — see step 6.5 below.

### 4. Journey time from home (Svatovítská 16, Praha)

Use `WebSearch` / `WebFetch` against Google Maps or Mapy.cz to look up the
public-transport journey time to the venue on the day of the event. Compute
the departure time so the user arrives **15 minutes before the start**:

```
departure = concert_start - 15 min - journey_time
```

Round to the nearest 5 minutes. Keep it for the event description and the
email.

### 5. Resolve KP API base + bearer token

```bash
KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.example.com}"
KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --fields label=credential --reveal 2>/dev/null)"
if [ -z "$KP_TOKEN" ]; then
  echo "no PAT in 1Password — falling back to .env"
  set -a; . ~/Documents/Dev/kulturniprehled/.env 2>/dev/null; set +a
  KP_TOKEN="${KP_API_TOKEN:-}"
fi
[ -n "$KP_TOKEN" ] || { echo "no Kulturní Přehled token available, run scripts/mint-pat.sh first"; exit 1; }
```

If neither source has a token, mint one and store it:

```bash
PAT=$(~/Documents/Dev/kulturniprehled/scripts/mint-pat.sh petr@example.com 'desktop-skill')
op item edit 'Kulturni Prehled API Token' "credential=$PAT"
```

**Cloudflare WAF gotcha.** The default `curl` user-agent is sometimes
blocked with a 403 (error code 1010). Pass `-A 'kp-skill/1.0'` (or any
non-curl UA) on every request below.

### 6. Create the event in KP

The cover / venue image URLs are PATCH-ed in step 6.5 after we have
an `EVENT_ID` to upload under, so the POST below only sends the
address + notes; the URL fields stay null for one frame.

```bash
EVENT_RESPONSE=$(curl -fsS -A 'kp-skill/1.0' \
  -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
    --arg title "$EVENT_TITLE" \
    --arg cat "$EVENT_CATEGORY" \
    --arg start "$EVENT_STARTS_AT_ISO" \
    --arg tz "$EVENT_TIMEZONE" \
    --arg notes "$EVENT_NOTES" \
    --arg venue_address "$EVENT_VENUE_ADDRESS" \
    --arg departure "$EVENT_DEPARTURE_AT_ISO" \
    '{title:$title, category:$cat, starts_at:$start, venue_timezone:$tz,
      source:"skill", notes:$notes,
      venue_address:(if $venue_address=="" then null else $venue_address end),
      departure_at:(if $departure=="" then null else $departure end)}')" \
  "$KP_API_BASE/v1/events")
EVENT_ID=$(printf '%s' "$EVENT_RESPONSE" | jq -r '.id')
[ -n "$EVENT_ID" ] && [ "$EVENT_ID" != "null" ] \
  || { echo "event creation failed: $EVENT_RESPONSE"; exit 1; }
```

Fields:

- `EVENT_TITLE` — performer / play / film name
- `EVENT_CATEGORY` — `concert` / `theatre` / `cinema` / `other`
- `EVENT_STARTS_AT_ISO` — start in ISO 8601 with timezone, e.g.
  `2026-06-12T20:00:00+02:00`
- `EVENT_TIMEZONE` — IANA tz, e.g. `Europe/Prague`
- `EVENT_NOTES` — Czech-formatted: program (or "Program zatím
  nezveřejněn"), seat info, departure time + transit hint. **Do not
  include a `Místo:` block** — venue is rendered separately on mobile
  from `venue_address` / `venue_image_url`, repeating it inline is
  redundant.
- `EVENT_VENUE_ADDRESS` — full venue address as a single string,
  e.g. `Rudolfinum, Alšovo nábřeží 12, 110 00 Praha 1`. **Required**
  for the "Mapa" button to work.
- `EVENT_DEPARTURE_AT_ISO` — ISO 8601 of when the user needs to
  leave home to arrive 15 min before the show, computed in step 4
  from journey time. The mobile app fires a "leave in 10 min"
  local notification 10 minutes before this timestamp. Leave empty
  if journey lookup failed; the notification just gets skipped.

### 6.5. Upload resized cover + venue → PATCH event

For each of the two images (`cover` from step 3, `venue` from step 3):

```bash
# 1. Ask KP for a presigned PUT into the public images bucket.
RESP=$(curl -fsS -A 'kp-skill/1.0' \
  -H "Authorization: Bearer $KP_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg kind "$KIND" --arg ext jpg \
    '{kind:$kind, extension:$ext}')" \
  "$KP_API_BASE/v1/events/$EVENT_ID/images/upload-url")
PUT_URL=$(printf '%s' "$RESP" | jq -r '.upload_url')
PUBLIC_URL=$(printf '%s' "$RESP" | jq -r '.public_url')

# 2. PUT the resized 960 px JPEG. -A is required (CF WAF) and -g lets
# brackets through in the (presigned) URL.
curl -fsS -g -A 'kp-skill/1.0' --upload-file "$RESIZED_PATH" "$PUT_URL"

# 3. Sanity-check the object is now publicly fetchable.
curl -sSI -A 'kp-skill/1.0' "$PUBLIC_URL" | head -1   # expect 200
```

Once both `COVER_PUBLIC_URL` and `VENUE_PUBLIC_URL` exist, PATCH the
event with both URLs in one shot (version starts at 1 from the POST
above; bump per PATCH):

```bash
curl -fsS -A 'kp-skill/1.0' -X PATCH \
  -H "Authorization: Bearer $KP_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson v 1 \
    --arg cover "$COVER_PUBLIC_URL" --arg venue_img "$VENUE_PUBLIC_URL" \
    '{version:$v, cover_image_url:$cover, venue_image_url:$venue_img}')" \
  "$KP_API_BASE/v1/events/$EVENT_ID" \
  | jq '{cover_image_url, venue_image_url, version}'
```

The PATCH response should echo both URLs back — if either field
shows `null`, the backend silently dropped it (see test
`test_create_persists_image_urls_and_venue_address`).

### 7. Upload each ticket PDF to KP MinIO

For every ticket PDF (use the `/tmp/<clean>.pdf` copy if the original
filename had brackets — see step 1):

```bash
NAME=$(basename "$PDF_PATH")
SIZE=$(stat -c '%s' "$PDF_PATH")
UPLOAD=$(curl -fsS -A 'kp-skill/1.0' \
  -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg event_id "$EVENT_ID" --arg mime application/pdf \
    --arg name "$NAME" --arg size "$SIZE" \
    '{event_id:$event_id, mime_type:$mime, original_filename:$name,
      size_bytes:($size|tonumber)}')" \
  "$KP_API_BASE/v1/tickets/upload-url")
OBJECT_KEY=$(printf '%s' "$UPLOAD" | jq -r '.object_key')
PUT_URL=$(printf '%s' "$UPLOAD" | jq -r '.upload_url')

curl -fsS -g -A 'kp-skill/1.0' --upload-file "$PDF_PATH" "$PUT_URL"

HASH=$(sha256sum "$PDF_PATH" | awk '{print $1}')
curl -fsS -A 'kp-skill/1.0' \
  -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg event_id "$EVENT_ID" --arg key "$OBJECT_KEY" \
    --arg mime application/pdf --arg name "$NAME" --arg size "$SIZE" \
    --arg hash "$HASH" \
    '{event_id:$event_id, object_key:$key, mime_type:$mime,
      original_filename:$name, size_bytes:($size|tonumber),
      hash_sha256:$hash}')" \
  "$KP_API_BASE/v1/tickets" >/dev/null
```

If any of these calls fail (non-2xx), abort the whole flow and report
which step failed — do not run the Google-side steps with a partial KP
state.

### 8. Record the ticket price as a cost (feeds Stats)

For every ticket post a `cost` row so the price lands in the Stats
screen (PODLE KATEGORIE + roční útrata). One POST per ticket — same
ticket count as step 7 — keeps the totals honest and lets the price
travel with the ticket if you ever delete just one.

```bash
TODAY=$(date -I)            # ISO date, e.g. 2026-05-18
PRICE_CENTS=169000          # 1690 Kč → 169000; from step 2

curl -fsS -A 'kp-skill/1.0' \
  -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson cents "$PRICE_CENTS" --arg paid_at "$TODAY" \
    '{amount_cents:$cents, kind:"ticket", split:"shared",
      paid_at:$paid_at}')" \
  "$KP_API_BASE/v1/events/$EVENT_ID/costs" >/dev/null
```

`split: "shared"` halves the spend between Petr + Běla in the per-user
Stats view; switch to `"mine"` for solo trips. `kind: "ticket"` is what
the PODLE KATEGORIE breakdown rolls up under "Vstupné" / similar.

If the price is free (e.g. free pre-festival event), skip this step
entirely — don't post a zero cost; it just clutters the Stats list.

### 8.5. Build / update the Spotify playlist (concerts only)

Skip unless `EVENT_CATEGORY == concert`. **Non-fatal**: if any Spotify
call fails (missing 1Password item, expired refresh token, search misses),
log `WARN: spotify step failed — <reason>`, set `PLAYLIST_URL=""` and
continue with step 9 — never abort the ingest over the playlist.

#### a. Access token

```bash
SP_CLIENT_ID=$(op item get 'Spotify Web API (Kulturni Prehled)' --fields label=client_id --reveal)
SP_CLIENT_SECRET=$(op item get 'Spotify Web API (Kulturni Prehled)' --fields label=client_secret --reveal)
SP_REFRESH=$(op item get 'Spotify Web API (Kulturni Prehled)' --fields label=refresh_token --reveal)
SP_TOKEN=$(curl -sS -X POST https://accounts.spotify.com/api/token \
  -u "$SP_CLIENT_ID:$SP_CLIENT_SECRET" \
  -d grant_type=refresh_token -d refresh_token="$SP_REFRESH" | jq -r .access_token)
[ -n "$SP_TOKEN" ] && [ "$SP_TOKEN" != "null" ] || { echo "WARN: spotify auth failed"; SP_TOKEN=""; }
```

#### b. Pick the tracks (LLM step — you, the skill runner, ARE the curator)

Two modes:

- **Program known** (the `{composer, work}` / line-up list from step 3):
  for each work, in program order, find the **complete recording — all
  movements**. Recording priority:
  1. the concert's own performers / conductor (closest to the live sound),
  2. else a canonical, well-regarded recording,
  3. else the top search hit.
- **Program unknown**: the headline performer's **latest album in full**
  (for a classical soloist/ensemble: their most recent release).

Search via the Web API (NOT the claude.ai Spotify MCP — that one cannot
target playlists):

```bash
# find the album carrying the work (URL-encode the query)
curl -sS -H "Authorization: Bearer $SP_TOKEN" \
  -G 'https://api.spotify.com/v1/search' \
  --data-urlencode "q=Mahler Symphony No. 5 Bychkov Czech Philharmonic" \
  --data-urlencode 'type=album' --data-urlencode 'limit=5'
# then list its tracks and keep the ones belonging to the work
curl -sS -H "Authorization: Bearer $SP_TOKEN" \
  "https://api.spotify.com/v1/albums/$ALBUM_ID/tracks?limit=50"
```

For the latest-album fallback: search `type=artist`, take the best name
match, then `GET /v1/artists/$ARTIST_ID/albums?include_groups=album&limit=1`
(results are newest-first) and add every track of that album.

Collect the chosen track URIs (`spotify:track:...`) into `$TRACK_URIS_JSON`
(a JSON array, program order). If it ends up empty, treat as failure (warn +
skip the rest of 8.5).

#### c. Create or update the playlist (idempotent)

The KP event remembers its playlist. Re-running the same concert must
UPDATE, never duplicate:

```bash
EXISTING_URL=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  "$KP_API_BASE/v1/events/$EVENT_ID" | jq -r '.spotify_playlist_url // empty')

PL_NAME="KP • ${EVENT_DATE_ISO} • ${EVENT_TITLE} — ${VENUE_SHORT}"   # e.g. KP • 2026-06-12 • Sokolov — Rudolfinum
PL_DESC="${PROGRAM_ONELINE} | ${VENUE_SHORT} | kulturniprehled"      # Spotify caps descriptions at 300 chars — truncate

if [ -n "$EXISTING_URL" ]; then
  PL_ID=${EXISTING_URL##*/}; PL_ID=${PL_ID%%\?*}
  curl -sS -X PUT -H "Authorization: Bearer $SP_TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$PL_NAME" --arg d "$PL_DESC" '{name:$n, description:$d, public:true}')" \
    "https://api.spotify.com/v1/playlists/$PL_ID"
else
  SP_USER=$(curl -sS -H "Authorization: Bearer $SP_TOKEN" https://api.spotify.com/v1/me | jq -r .id)
  PL_ID=$(curl -sS -X POST -H "Authorization: Bearer $SP_TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$PL_NAME" --arg d "$PL_DESC" '{name:$n, description:$d, public:true}')" \
    "https://api.spotify.com/v1/users/$SP_USER/playlists" | jq -r .id)
fi
PLAYLIST_URL="https://open.spotify.com/playlist/$PL_ID"

# Replace the full track list (PUT replaces; chunk: first 100 via PUT,
# any remainder via POST /tracks with {"uris": [...]}).
curl -sS -X PUT -H "Authorization: Bearer $SP_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson u "$TRACK_URIS_JSON" '{uris:($u[:100])}')" \
  "https://api.spotify.com/v1/playlists/$PL_ID/tracks"
```

#### d. Cover image

Reuse the event cover from step 3 (`/tmp/cover_960.jpg`), shrink to fit
Spotify's 256 KB base64 cap:

```bash
python3 - <<'PY'
from PIL import Image
src = Image.open("/tmp/cover_960.jpg")
src.thumbnail((600, 600))
src.convert("RGB").save("/tmp/pl_cover.jpg", "JPEG", quality=80, optimize=True)
PY
base64 -w0 /tmp/pl_cover.jpg | curl -sS -X PUT \
  -H "Authorization: Bearer $SP_TOKEN" -H 'Content-Type: image/jpeg' \
  --data-binary @- "https://api.spotify.com/v1/playlists/$PL_ID/images"
```

#### e. PATCH the event with the playlist URL

```bash
VERSION=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  "$KP_API_BASE/v1/events/$EVENT_ID" | jq -r .version)
curl -fsS -A 'kp-skill/1.0' -X PATCH \
  -H "Authorization: Bearer $KP_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson v "$VERSION" --arg url "$PLAYLIST_URL" \
    '{version:$v, spotify_playlist_url:$url}')" \
  "$KP_API_BASE/v1/events/$EVENT_ID" | jq '{spotify_playlist_url, version}'
```

### 9. Mirror to Google Drive

For each ticket file use `mcp__google-workspace__create_drive_file`:

- `user_google_email`: `petronijus@example.com`
- `file_name`: human-readable, e.g.
  `Anoushka Shankar — Rudolfinum 22.11.2026 — místo 19.pdf`
- `mime_type`: `application/pdf`
- `fileUrl`: `file://<absolute local path>` (the `/tmp/<clean>.pdf`
  copy from step 1 if applicable)

### 10. Create the calendar event

Use `mcp__google-workspace__create_event`:

- `user_google_email`: `petronijus@example.com`
- `calendar_id`:
  `c_9a5bbccc4605dfbee65ff6ec08e3259596e8fc63bb131db50438b28e9cfece87@group.calendar.google.com`
  (Kocourek&Prdelcicka)
- `summary`: emoji + performer + venue, e.g.
  `🎹 Grigorij Sokolov — Rudolfinum`
  (`🎹` for classical, `🎸` for rock/jazz, `🎭` for theatre, `🎬` for
  cinema)
- `start_time` / `end_time`: from the ticket (estimate end as start +
  2.5 h for concerts, + 1 h 45 m for theatre, + 2 h for cinema)
- `timezone`: `Europe/Prague`
- `location`: full venue address
- `attendees`: `["bela@example.com"]`
- `attachments`: Drive file IDs of all uploaded tickets from step 9
- `use_default_reminders`: `false` (no reminders)
- `description`:

```
[Festival / organizer name if available]

Místa: [sector, row, seat numbers for all tickets]

🚌 Odjezd ze Svatovítské 16: [departure time] (MHD, ~[N] min,
   příjezd 15 min před začátkem)

🎧 Playlist: $PLAYLIST_URL

Program: [from website, or note that it hasn't been announced yet]

Vstupenky v KP: $KP_API_BASE/v1/events/$EVENT_ID
```

Omit the `🎧 Playlist:` line when `PLAYLIST_URL` is empty — non-concert events and Spotify failures.

### 11. Report back

Reply to the user in Czech:

- "Hotovo. V Kulturním přehledu jsi {EVENT_TITLE} na {DATETIME} v
  {VENUE}. Lístky ({N} ks, {TOTAL_PRICE_CZK}) jsou nahraný v KP i na
  Drivu, kalendář hotový. Playlist na přípravu: {PLAYLIST_URL}. Běla dostane notifikaci v appce automaticky
  (background sync, max 30 min)." (Omit the "Playlist na přípravu:" sentence when `PLAYLIST_URL` is empty.)
- Include the KP event id and the Drive links.

*Email Běle odebrán — appka teď posílá push-style lokální notifikaci
při syncu nových eventů (viz `sync_controller.dart`).*

### Notes

- bastla account: `petronijus@example.com`
- Běla: `bela@example.com` — **always with háček: Běla / Bělo**
- Calendar: Kocourek&Prdelcicka
- KP API base: dev `http://localhost:18000`, prod
  `https://kulturniprehled.example.com`
- **Parsing JSON responses — never `echo "$VAR" | jq`.** The dev
  MacBook's shell is `zsh`, whose builtin `echo` interprets backslash
  escapes, so a perfectly valid response with an escaped newline in
  `notes` (`"...ročník\n\nSezení..."`) gets turned into raw control
  characters before `jq` sees it → `jq: parse error: Invalid string:
  control characters... must be escaped`. The API is fine; `echo` is
  the culprit. Use `printf '%s' "$VAR" | jq ...` (portable across bash
  + zsh), or pipe `curl ... | jq` directly with no intermediate
  variable. Same applies to `python3 -c 'json.load(...)'`.
- MCP namespace for the Google Workspace tools is **per-machine** —
  it depends on what the connected MCP server registered itself as.
  Seen in the wild: `mcp__google-workspace__*` and
  `mcp__workspace-mcp__*`. Don't hardcode one; use whichever Drive /
  Calendar tool is actually exposed in the current session.
- If the user passes arguments (specific file name, different guest),
  use those instead of defaults.
- KP API errors: surface the HTTP body to the user — most failures
  (401, 422, 409) point at a fixable misconfiguration in the .env or
  1Password.
- Rate-limit (per IP, slowapi): 10/min on `/v1/auth/google`, 30/min on
  `/v1/auth/refresh`, 120/min on everything else. The skill stays well
  under the limit; if you see a 429, you're either looped or another
  process is hammering the API.
- Spotify Web API credentials live in 1Password item
  `Spotify Web API (Kulturni Prehled)` (`client_id`, `client_secret`,
  `refresh_token`); scopes `playlist-modify-public ugc-image-upload`.
  One-time setup in README.md. The claude.ai Spotify MCP is NOT a
  substitute — it cannot add tracks to an existing playlist.
