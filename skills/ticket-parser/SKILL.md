---
name: kulturni-prehled-ingest
description: Processes downloaded cultural-event tickets — registers the event and uploads the ticket files into the Kulturní Přehled backend, then mirrors the event into the shared Google Calendar, uploads tickets to Google Drive, and emails Běla.
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

### 2. Extract metadata from the tickets

Read each PDF and extract:

- Performer / play / film title
- Category — one of `concert`, `theatre`, `cinema`, `other`
- Date and time (start), including timezone
- Venue name + full address (for Google Calendar) + city
- Seat info (sector, row, seat numbers) — keep for the event description
  and the email

Use the **`category`** that best matches: classical/rock/jazz → `concert`,
divadlo → `theatre`, kino → `cinema`, otherwise `other`.

### 3. Journey time from home (Svatovítská 16, Praha)

Use `WebSearch` / `WebFetch` against Google Maps or Mapy.cz to look up the
public-transport journey time to the venue on the day of the event. Compute
the departure time so the user arrives **15 minutes before the start**:

```
departure = concert_start - 15 min - journey_time
```

Round to the nearest 5 minutes. Keep it for the event description and the
email.

### 4. Find the program (optional)

Try the organizer's website for the program / line-up. If it isn't
published, say so — do not invent it.

### 5. Resolve KP API base + bearer token

```bash
KP_API_BASE="${KP_API_BASE:-http://localhost:18000}"
KP_TOKEN="$(op-cache 'Kulturni Prehled API Token' credential 2>/dev/null || true)"
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

### 6. Create the event in KP

```bash
EVENT_ID=$(curl -fsS \
  -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
    --arg title "$EVENT_TITLE" \
    --arg cat "$EVENT_CATEGORY" \
    --arg start "$EVENT_STARTS_AT_ISO" \
    --arg tz "$EVENT_TIMEZONE" \
    --arg notes "$EVENT_NOTES" \
    '{title:$title, category:$cat, starts_at:$start, venue_timezone:$tz,
      source:"skill", notes:$notes}')" \
  "$KP_API_BASE/v1/events" | jq -r '.id')
[ -n "$EVENT_ID" ] && [ "$EVENT_ID" != "null" ] || { echo "event creation failed"; exit 1; }
```

Where:

- `EVENT_TITLE` — Performer / play / film name
- `EVENT_CATEGORY` — `concert` / `theatre` / `cinema` / `other`
- `EVENT_STARTS_AT_ISO` — start in ISO 8601 with timezone, e.g. `2026-06-12T20:00:00+02:00`
- `EVENT_TIMEZONE` — IANA tz, e.g. `Europe/Prague`
- `EVENT_NOTES` — Czech-formatted: program (or "Program zatím nezveřejněn"),
  seat info, departure time + transit hint

### 7. Upload each ticket to KP MinIO

For every ticket PDF:

```bash
UPLOAD=$(curl -fsS \
  -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
    --arg event_id "$EVENT_ID" \
    --arg mime "application/pdf" \
    --arg name "$(basename "$PDF_PATH")" \
    --arg size "$(stat -c '%s' "$PDF_PATH")" \
    '{event_id:$event_id, mime_type:$mime, original_filename:$name,
      size_bytes:($size|tonumber)}')" \
  "$KP_API_BASE/v1/tickets/upload-url")
OBJECT_KEY=$(echo "$UPLOAD" | jq -r '.object_key')
PUT_URL=$(echo "$UPLOAD" | jq -r '.upload_url')

curl -fsS --upload-file "$PDF_PATH" "$PUT_URL"

HASH=$(sha256sum "$PDF_PATH" | awk '{print $1}')
curl -fsS \
  -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
    --arg event_id "$EVENT_ID" \
    --arg key "$OBJECT_KEY" \
    --arg mime "application/pdf" \
    --arg name "$(basename "$PDF_PATH")" \
    --arg size "$(stat -c '%s' "$PDF_PATH")" \
    --arg hash "$HASH" \
    '{event_id:$event_id, object_key:$key, mime_type:$mime,
      original_filename:$name, size_bytes:($size|tonumber),
      hash_sha256:$hash}')" \
  "$KP_API_BASE/v1/tickets" >/dev/null
```

If any of these calls fail (non-2xx), abort the whole flow and report
which step failed — do not run the Google-side steps with a partial KP
state.

### 8. Mirror to Google Drive

For each ticket file use `mcp__workspace-mcp__create_drive_file`:

- `user_google_email`: `petronijus@example.com`
- Sensible name after the performer.

### 9. Create the calendar event

Use `mcp__workspace-mcp__manage_event`:

- `user_google_email`: `petronijus@example.com`
- `calendar_id`: `c_9a5bbccc4605dfbee65ff6ec08e3259596e8fc63bb131db50438b28e9cfece87@group.calendar.google.com`
  (Kocourek&Prdelcicka)
- `summary`: emoji + performer + venue, e.g. `🎹 Grigorij Sokolov — Rudolfinum`
  (use `🎹` for classical, `🎸` for rock/jazz, `🎭` for theatre, `🎬` for cinema)
- `start_time` / `end_time`: from the ticket (estimate end as start + 2.5 h
  for concerts, + 1 h 45 m for theatre, + 2 h for cinema)
- `timezone`: `Europe/Prague`
- `location`: full venue address
- `attendees`: `["bela@example.com"]`
- `attachments`: Drive file IDs of all uploaded tickets
- `description`:

```
[Festival / organizer name if available]

Místa: [sector, row, seat numbers for all tickets]

🚌 Odjezd z Dejvic: [departure time] (MHD ze Svatovítské 16,
   příjezd 15 min před začátkem)

Program: [from website, or note that it hasn't been announced yet]

Vstupenky:
• KP: https://api.kp.example.com/v1/events/[EVENT_ID]
• Drive: [drive link(s)]
```

- No reminders.

### 10. Email Běla

Use `mcp__workspace-mcp__send_gmail_message`:

- `user_google_email`: `petronijus@example.com`
- `to`: `bela@example.com`
- Always address her as **"Bělo"** (with háček — never "Belo")
- Brief friendly Czech message: performer, date, time, venue, seat
  numbers, departure time from Svatovítská 16.
- `attachments`: local file paths of all ticket PDFs.

### 11. Report back

Reply to the user in Czech:

- "Hotovo. V Kulturním přehledu jsi {EVENT_TITLE} na {DATETIME} v {VENUE}.
  Listky ({N} ks) jsou nahraný v KP i na Drivu, kalendář a mail Bělo
  hotový."
- Include the KP event id and the Drive links.

### Notes

- bastla account: `petronijus@example.com`
- Běla: `bela@example.com` — **always with háček: Běla / Bělo**
- Calendar: Kocourek&Prdelcicka
- KP API base: dev `http://localhost:18000`, prod `https://api.kp.example.com`
- If the user passes arguments (specific file name, different guest), use
  those instead of defaults.
- KP API errors: surface the HTTP body to the user — most failures (401,
  422, 409) point at a fixable misconfiguration in the .env or 1Password.
