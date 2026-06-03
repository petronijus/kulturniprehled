# Spotify concert playlists — design

Date: 2026-06-03
Author: Petr (+ Claude)
Status: Approved for planning

## Goal

When a concert ticket is ingested via the `kulturni-prehled-ingest` skill,
also build a Spotify playlist that previews **what will be played** at that
concert, so Petr (and Běla) can prepare by listening beforehand.

One playlist **per concert**, organized so re-running the skill never
produces duplicate playlists, and so each concert's playlist is easy to find
— from Spotify, from the mobile app, and from the Google Calendar event.

## Scope

In scope:

- Only events with `category == concert` (classical, jazz, rock,
  electronica). Theatre and cinema are explicitly out.
- Extends the existing `skills/ticket-parser/SKILL.md` pipeline with one new
  step, plus a one-time Spotify Web API credential setup.
- Full-stack: new `spotify_playlist_url` field on the event, synced to
  mobile, surfaced as a button on the concert detail screen and as a line in
  the Google Calendar event description.

Out of scope (YAGNI):

- Spotify **folders** — not manageable via the Web API. Replaced by a name
  prefix + per-playlist cover art.
- Playlists for theatre / cinema.
- Auto-deletion / archiving of past-concert playlists (date in the name keeps
  them tidy; can be added later).
- The recommendation-engine experts (`klasika-expert` et al.) — unrelated.

## Why the Spotify Web API, not the claude.ai Spotify MCP

The claude.ai Spotify MCP is a **widget** integration, unsuitable here:

- `create_playlist` takes only a natural-language prompt and creates a **new**
  playlist every call — it cannot target an existing playlist or add specific
  tracks. That is exactly the "pile of new playlists" we want to avoid.
- `add_to_library` / `fetch_tracks` are explicitly forbidden outside the
  widget and require a signature obtained from the widget UI — unusable from a
  headless skill.
- Playlists are private and Premium-only.

The **Spotify Web API** (OAuth, driven by `curl`, the same pattern the skills
already use for Discogs and the KP API) supports searching for a specific
recording, creating *or updating* a playlist by id, replacing/ordering tracks,
setting name/description, and setting a custom cover image. It is the only
path that meets the requirements.

## Idempotency

"Idempotent" = running the skill twice for the same concert yields the same
single playlist, not duplicates.

Mechanism: the event row stores `spotify_playlist_url`. On each run the skill:

- if the event already has a `spotify_playlist_url` → **replace** that
  playlist's tracks (`PUT /v1/playlists/{id}/tracks`), refresh description and
  cover. No new playlist.
- if empty → create a new playlist, then `PATCH` the event with its URL.

The single stored field serves both idempotency **and** the app/calendar
links — one field, two uses.

## Playlist shape

- **Name**: `KP • 2026-06-12 • Sokolov — Rudolfinum`
  (`KP ` prefix groups them; ISO date sorts chronologically;
  `interpret — venue` identifies the concert).
- **Description**: program (composer — work lines, or "Program zatím
  nezveřejněn"), venue, and a link back to the KP event.
- **Cover image**: the event's cover image, reused from the skill's existing
  step 3 output (the 960 px JPEG), downscaled to ≤300 px and uploaded via
  `PUT /v1/playlists/{id}/images` (needs `ugc-image-upload` scope).
- **Visibility**: **public**, so the shared link works for Běla.

## Track selection (the LLM reasoning step in the skill)

Mirrors how `klasika-expert` reasons over candidates — the skill runner *is*
the LLM and curates.

1. **Program known** (list of `{composer, work}` from skill step 3): for each
   work, add the **complete work, all movements in program order**.
   Recording choice priority:
   1. a recording by **the concert's own performers / conductor** (closest to
      what will be heard live),
   2. else a canonical / well-regarded recording,
   3. else the top search hit.
   Long programs are kept complete regardless of total length (per decision:
   "vždy celá díla").
2. **Program not known**: take the **headline performer/artist** and add their
   **latest album in full**. For a classical soloist/ensemble with no listed
   program, use their most recent released recording.

Track ordering follows the concert program order (or album order for the
fallback).

## Failure handling

The Spotify step is **non-fatal**. If token resolution, search, or any Spotify
call fails, log it and continue — the KP event, ticket uploads, cost, Drive
mirror, and calendar event still complete. A concert without a playlist is
acceptable; a half-ingested ticket is not.

## Credentials (one-time setup)

A Spotify Web API app registered once. Stored in 1Password item
`Spotify Web API (Kulturní Přehled)` with fields `client_id`, `client_secret`,
`refresh_token`. Scopes: `playlist-modify-public`, `ugc-image-upload`.

At runtime the skill exchanges the refresh token for a short-lived access
token (`POST https://accounts.spotify.com/api/token`). Documented in the skill
the same way `mint-pat.sh` and the Discogs key are.

## Affected layers

Single PR (per decision: "naráz celé").

### Backend (`apps/api`)

- Migration `0013_event_spotify_playlist`: add
  `spotify_playlist_url VARCHAR(1024) NULL` to `events`.
- `domain/models.py`: add the column to `Event`.
- `domain/schemas.py`: add `spotify_playlist_url` to `EventCreate`,
  `EventUpdate`, `EventResponse` (follow `cover_image_url`, max_length 1024).
- `sync/changelog.py`: add `spotify_playlist_url` to `_event_payload` (next to
  `cover_image_url` at line ~53) so it reaches mobile via the change_log.
- `api/v1/events.py`: accept the field on POST/PATCH (Pydantic carries it).
- Tests: extend the event create/patch persistence test
  (`test_create_persists_image_urls_and_venue_address` analog) to assert the
  field round-trips and appears in the sync payload.

### Mobile (`apps/mobile`)

- `features/events/event_dto.dart`: add `spotifyPlaylistUrl` field, `fromMap`
  (`spotify_playlist_url`), and the drift companion mapping — following the
  `coverImageUrl` lines exactly.
- `data/drift/database.dart`: add the column to the Events table and bump
  `schemaVersion` with a migration step.
- `features/events/event_detail_screen.dart`: add a "🎧 Playlist" button
  (shown only when `spotifyPlaylistUrl != null`) that opens the URL via
  `url_launcher` (already a dependency, `^6.3.1`) — mirror the existing "Mapa"
  button.
- Tests: a widget test asserting the button shows when the URL is present and
  is hidden when null.

### Skill (`skills/ticket-parser/SKILL.md`)

- New step (after event creation + program lookup, before/with the calendar
  step): "Build the Spotify playlist" — token resolution, track selection
  reasoning (above), create-or-update, cover upload, `PATCH` the event with
  the playlist URL.
- New setup subsection documenting the Spotify app + 1Password item.
- Step 10 (calendar): add a `🎧 Playlist: <url>` line to the event
  description.
- Step 11 (report-back): mention the playlist in the Czech summary.

## Testing strategy

- Backend: pytest, real Postgres (testcontainers) — field persists on
  create/patch and is present in the sync pull payload.
- Mobile: `flutter test` widget test for the conditional button.
- Skill: manual end-to-end on a real concert ticket (the skill has no
  automated test harness) — verify playlist created, cover set, event PATCHed,
  app button + calendar line appear after sync.

## Open questions

None blocking. Recording-quality heuristics ("canonical recording") are
left to the LLM's judgement at run time, consistent with the existing
`klasika-expert` ranking approach.
