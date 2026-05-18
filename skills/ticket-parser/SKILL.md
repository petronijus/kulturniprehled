---
name: kulturni-prehled-ingest
description: Processes downloaded cultural-event tickets — registers the event with cover/venue images and price in the Kulturní Přehled backend, then mirrors the event into the shared Google Calendar, uploads tickets to Google Drive, and emails Běla.
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

### 3. Find the program + images (mandatory)

The mobile detail screen always wants three things populated. Treat all
three as required — if a search comes up empty, try one more angle
before giving up.

- **`cover_image_url`** — a press / promo / album photo of the
  performer / ensemble / play / film. Prefer Wikipedia infobox image
  (Wikimedia Commons CDN, always a `https://upload.wikimedia.org/...`
  URL), the organizer's event page hero image, or the artist's
  official site. Direct image URL, **not the HTML page**.

  **Use the right Wikimedia URL form**, otherwise the mobile detail
  screen spends 5+ seconds downloading a 5-10 MB original just to
  paint a 300 px circle:

  - **Preferred**: `https://commons.wikimedia.org/wiki/Special:FilePath/<Name>.<ext>?width=800`
    — auto-redirects to the nearest pre-cached thumb. Always 200.
    Store the **resolved** URL (after the redirect) so the mobile app
    doesn't pay the redirect cost on every load:
    ```bash
    curl -sIL -A 'Mozilla/5.0' "$URL" | awk '/^[Ll]ocation: /{print $2}' \
      | tail -1 | sed 's/?utm_.*//'
    ```
  - **Direct thumb**, if you know a width that exists:
    `/wikipedia/commons/thumb/<h1>/<h2>/<Name>.jpg/960px-<Name>.jpg`.
    Empirically the "always-works" widths are `500`, `960`, and
    `1280` — every other number (320, 640, 800, 1024) often 400s.
    `960` is the sweet spot for mobile: ~200-350 KB JPG, sharp at the
    300 px agenda circle on a 3x DPR phone and on the wider detail
    cover.
  - **Never use the original** (`/wikipedia/commons/<h1>/<h2>/<Name>.jpg`
    without `/thumb/`). It returns the source upload — Anoushka
    Shankar's was 8.4 MB and stalled the cover for ~5 s on the agenda.
- **`venue_image_url`** — a photo of the venue building. Wikipedia
  Commons is the easiest source for the established venues (Rudolfinum,
  Forum Karlín, Lucerna, Fórum, …); for festival sites use the
  organizer page hero. Same "use the original, drop `/thumb/`" rule
  applies.

After picking each URL, sanity-check it actually returns image bytes
**and isn't oversized** before posting to KP — otherwise the mobile
app either gets stuck on the fallback icon or spends seconds
downloading a multi-MB original:

```bash
read -r status bytes < <(
  curl -sS -A 'Mozilla/5.0' -o /dev/null -w "%{http_code} %{size_download}" "$URL"
)
[ "$status" = "200" ] || { echo "  bad URL ($status): $URL"; }
[ "$bytes" -lt 500000 ] || \
  echo "  warning: $((bytes / 1024)) KB — consider a smaller thumb"
```
- **Program / line-up** — try the organizer's event detail page first,
  then any festival schedule. Capture conductor, soloists, work names,
  opening act. If genuinely not published, say so in the notes — do
  not invent.

Do not link image-search result pages or Google Image hotlinks. If you
can only find an image embedded on a JS-heavy page, fetch that page
and copy the rendered `<img src>` URL, not the page URL.

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
    --arg venue_image_url "$EVENT_VENUE_IMAGE_URL" \
    --arg cover_image_url "$EVENT_COVER_IMAGE_URL" \
    '{title:$title, category:$cat, starts_at:$start, venue_timezone:$tz,
      source:"skill", notes:$notes,
      venue_address:(if $venue_address=="" then null else $venue_address end),
      venue_image_url:(if $venue_image_url=="" then null else $venue_image_url end),
      cover_image_url:(if $cover_image_url=="" then null else $cover_image_url end)}')" \
  "$KP_API_BASE/v1/events")
EVENT_ID=$(echo "$EVENT_RESPONSE" | jq -r '.id')
[ -n "$EVENT_ID" ] && [ "$EVENT_ID" != "null" ] \
  || { echo "event creation failed: $EVENT_RESPONSE"; exit 1; }

# Sanity-check the response actually persisted the URLs + address —
# silently dropped fields are how the skill produced events without
# covers / maps before (regression-tested in test_events.py).
echo "$EVENT_RESPONSE" | jq '{cover_image_url, venue_image_url, venue_address}'
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
- `EVENT_VENUE_IMAGE_URL` — direct URL to a venue building photo
  (step 3). **Required.**
- `EVENT_COVER_IMAGE_URL` — direct URL to the cover image (step 3).
  **Required.**

If the sanity-check echo prints any of the three as `null`, fix the
input (typo, missing variable, server-side validation rejecting the
URL) and PATCH the event before moving on:

```bash
curl -fsS -A 'kp-skill/1.0' -X PATCH \
  -H "Authorization: Bearer $KP_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson version 1 --arg cover "$EVENT_COVER_IMAGE_URL" \
    --arg venue_img "$EVENT_VENUE_IMAGE_URL" --arg venue_addr "$EVENT_VENUE_ADDRESS" \
    '{version:$version, cover_image_url:$cover,
      venue_image_url:$venue_img, venue_address:$venue_addr}')" \
  "$KP_API_BASE/v1/events/$EVENT_ID"
```

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
OBJECT_KEY=$(echo "$UPLOAD" | jq -r '.object_key')
PUT_URL=$(echo "$UPLOAD" | jq -r '.upload_url')

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

Program: [from website, or note that it hasn't been announced yet]

Vstupenky v KP: $KP_API_BASE/v1/events/$EVENT_ID
```

### 11. Email Běla

Use `mcp__google-workspace__send_gmail_message`:

- `user_google_email`: `petronijus@example.com`
- `to`: `bela@example.com`
- Always address her as **"Bělo"** (with háček — never "Belo" or
  "Bělka")
- Brief friendly Czech message: performer, date, time, venue, seat
  numbers, departure time from Svatovítská 16.
- `attachments`: local file paths of all ticket PDFs (the `/tmp` clean
  copies if applicable).

### 12. Report back

Reply to the user in Czech:

- "Hotovo. V Kulturním přehledu jsi {EVENT_TITLE} na {DATETIME} v
  {VENUE}. Lístky ({N} ks, {TOTAL_PRICE_CZK}) jsou nahraný v KP i na
  Drivu, kalendář a mail Bělo hotový."
- Include the KP event id and the Drive links.

### Notes

- bastla account: `petronijus@example.com`
- Běla: `bela@example.com` — **always with háček: Běla / Bělo**
- Calendar: Kocourek&Prdelcicka
- KP API base: dev `http://localhost:18000`, prod
  `https://kulturniprehled.example.com`
- MCP namespace is `mcp__google-workspace__*` (older skill versions
  said `mcp__workspace-mcp__*` — wrong).
- If the user passes arguments (specific file name, different guest),
  use those instead of defaults.
- KP API errors: surface the HTTP body to the user — most failures
  (401, 422, 409) point at a fixable misconfiguration in the .env or
  1Password.
- Rate-limit (per IP, slowapi): 10/min on `/v1/auth/google`, 30/min on
  `/v1/auth/refresh`, 120/min on everything else. The skill stays well
  under the limit; if you see a 429, you're either looped or another
  process is hammering the API.
