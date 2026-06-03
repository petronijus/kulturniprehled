# Spotify Concert Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the `kulturni-prehled-ingest` skill ingests a concert ticket, it also creates (or idempotently updates) a public Spotify playlist previewing the concert program, and the playlist URL is stored on the event, surfaced in the mobile app detail screen and the Google Calendar description.

**Architecture:** A new nullable `spotify_playlist_url` column on `events` travels the exact path `cover_image_url` already does: Pydantic schemas → create handler → `serialize_event` sync payload → mobile drift cache → detail screen. The playlist building itself is a new skill step using the Spotify Web API via `curl` + OAuth refresh token from 1Password (the same pattern as Discogs / KP tokens). Spec: `docs/superpowers/specs/2026-06-03-spotify-concert-playlists-design.md`.

**Tech Stack:** FastAPI + SQLAlchemy 2.0 async + Alembic (backend), Flutter + drift + Riverpod + url_launcher (mobile), Spotify Web API via curl (skill).

**Branch:** `feat/spotify-concert-playlists`, single PR into `main`.

---

### Task 0: Branch

- [ ] **Step 1: Create the feature branch**

```bash
cd /d/kulturniprehled
git checkout -b feat/spotify-concert-playlists
```

---

### Task 1: Backend — failing tests for the new field

**Files:**
- Modify: `apps/api/tests/test_events.py` (append after `test_create_persists_departure_at`)
- Modify: `apps/api/tests/test_sync.py` (append a new test)

- [ ] **Step 1: Write the failing round-trip test in `test_events.py`**

Append (uses the existing `_event_payload`, `login_as`, `auth_header` helpers already imported in this file):

```python
@pytest.mark.asyncio
async def test_create_persists_spotify_playlist_url(client: AsyncClient) -> None:
    # The ingest skill PATCHes the playlist URL after building the Spotify
    # playlist; the mobile app renders a "Playlist" link from it. Make sure
    # the field round-trips through POST + PATCH.
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    url = "https://open.spotify.com/playlist/3cEYpjA9oz9GiPac4AsH4n"
    create = await client.post(
        "/v1/events",
        json=_event_payload(spotify_playlist_url=url),
        headers=headers,
    )
    assert create.status_code == 201, create.text
    assert create.json()["spotify_playlist_url"] == url

    other = "https://open.spotify.com/playlist/5AbCdE9oz9GiPac4AsH4n"
    event_id = create.json()["id"]
    patch = await client.patch(
        f"/v1/events/{event_id}",
        json={"version": 1, "spotify_playlist_url": other},
        headers=headers,
    )
    assert patch.status_code == 200, patch.text
    assert patch.json()["spotify_playlist_url"] == other
```

- [ ] **Step 2: Write the failing sync-payload test in `test_sync.py`**

Append (same helper imports already at the top of the file):

```python
@pytest.mark.asyncio
async def test_event_sync_payload_includes_spotify_playlist_url(
    client: AsyncClient,
) -> None:
    # Mobile caches the change_log payload verbatim; the playlist link must
    # be part of serialize_event or the app never sees it.
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    url = "https://open.spotify.com/playlist/3cEYpjA9oz9GiPac4AsH4n"
    create = await client.post(
        "/v1/events",
        json={
            "title": "Sokolov",
            "category": "concert",
            "starts_at": "2026-09-01T19:30:00Z",
            "spotify_playlist_url": url,
        },
        headers=headers,
    )
    assert create.status_code == 201, create.text

    pull = (await client.get("/v1/sync?since=0", headers=headers)).json()
    payloads = [
        c["payload"]
        for c in pull["changes"]
        if c["entity_type"] == "event" and c["payload"]["title"] == "Sokolov"
    ]
    assert payloads, pull
    assert payloads[-1]["spotify_playlist_url"] == url
```

(`changes` / `next_seq` / `has_more` is the pull response shape — see
`sync/schemas.py:30`.)

- [ ] **Step 3: Run both tests to verify they fail**

```bash
cd /d/kulturniprehled/apps/api
uv run pytest tests/test_events.py::test_create_persists_spotify_playlist_url tests/test_sync.py::test_event_sync_payload_includes_spotify_playlist_url -q
```

Expected: FAIL — Pydantic `extra="forbid"` rejects `spotify_playlist_url` (422), so the 201 assertion trips.

---

### Task 2: Backend — migration, model, schemas, handlers

**Files:**
- Create: `apps/api/alembic/versions/0013_event_spotify_playlist.py`
- Modify: `apps/api/src/kp_api/domain/models.py` (Event, after `departure_at`, ~line 195)
- Modify: `apps/api/src/kp_api/domain/schemas.py` (EventCreate ~line 40, EventUpdate ~line 58, EventResponse ~line 78)
- Modify: `apps/api/src/kp_api/api/v1/events.py` (`create_event`, ~line 102)
- Modify: `apps/api/src/kp_api/sync/changelog.py` (`serialize_event`, ~line 56)

- [ ] **Step 1: Create the migration** (pattern copied from `0010_event_departure_at.py`)

```python
"""event spotify_playlist_url

Revision ID: 0013
Revises: 0012
Create Date: 2026-06-03

Adds optional `spotify_playlist_url` to `events`. The ingest skill builds a
public Spotify playlist previewing the concert program and PATCHes the URL
here; the mobile app renders a "Playlist" link from it. The stored URL also
serves as the idempotency key — a re-run updates the existing playlist
instead of creating a duplicate. Nullable: non-concert events and Spotify
failures leave it empty.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "events",
        sa.Column("spotify_playlist_url", sa.String(length=1024), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("events", "spotify_playlist_url")
```

- [ ] **Step 2: Add the column to the ORM model**

In `models.py`, `class Event`, directly below `departure_at`:

```python
    spotify_playlist_url: Mapped[str | None] = mapped_column(String(1024), nullable=True)
```

- [ ] **Step 3: Add the field to all three Pydantic schemas**

In `schemas.py` — `EventCreate` and `EventUpdate`, below `departure_at`:

```python
    spotify_playlist_url: str | None = Field(default=None, max_length=1024)
```

`EventResponse`, below `departure_at`:

```python
    spotify_playlist_url: str | None
```

- [ ] **Step 4: Pass the field through `create_event`**

In `api/v1/events.py`, the `Event(...)` constructor call, below `departure_at=body.departure_at,`:

```python
        spotify_playlist_url=body.spotify_playlist_url,
```

(PATCH needs no change — `update_event` applies `model_dump(exclude_unset=True)` generically. Same for `_apply_event_update` in `sync/service.py`, which validates against `EventUpdate` and therefore now accepts the field; its `exclude_unset=True` also guarantees mobile edits that omit the field never wipe it.)

- [ ] **Step 5: Add the field to the sync payload**

In `sync/changelog.py`, `serialize_event`, below `"departure_at": ...,`:

```python
        "spotify_playlist_url": event.spotify_playlist_url,
```

- [ ] **Step 6: Run the two new tests — verify they pass**

```bash
cd /d/kulturniprehled/apps/api
uv run pytest tests/test_events.py::test_create_persists_spotify_playlist_url tests/test_sync.py::test_event_sync_payload_includes_spotify_playlist_url -q
```

Expected: 2 passed.

- [ ] **Step 7: Run the full backend gate**

```bash
cd /d/kulturniprehled/apps/api
uv run ruff check . && uv run black --check . && uv run mypy src/kp_api && uv run pytest -q
```

Expected: all green (60+ tests).

- [ ] **Step 8: Commit**

```bash
cd /d/kulturniprehled
git add apps/api
git commit -m "feat(api): event spotify_playlist_url field + sync payload"
```

---

### Task 3: Mobile — drift schema v10 + DTO

**Files:**
- Modify: `apps/mobile/lib/data/drift/database.dart` (CachedEvents table ~line 32, `schemaVersion` ~line 184, `onUpgrade` ~line 218)
- Modify: `apps/mobile/lib/features/events/event_dto.dart`
- Modify: `apps/mobile/test/agenda_test.dart` (extend the db round-trip test)
- Generated: `apps/mobile/lib/data/drift/database.g.dart` (build_runner)

- [ ] **Step 1: Add the column to `CachedEvents`**

Below `DateTimeColumn get departureAt => dateTime().nullable()();`:

```dart
  TextColumn get spotifyPlaylistUrl => text().nullable()();
```

- [ ] **Step 2: Bump `schemaVersion` to 10 and add the migration step**

```dart
  int get schemaVersion => 10;
```

In `onUpgrade`, after the `if (from < 9)` block:

```dart
      if (from < 10) {
        await m.addColumn(cachedEvents, cachedEvents.spotifyPlaylistUrl);
      }
```

- [ ] **Step 3: Regenerate drift code**

```bash
cd /d/kulturniprehled/apps/mobile
dart run build_runner build --delete-conflicting-outputs
```

Expected: succeeds, `database.g.dart` regenerated.

- [ ] **Step 4: Add the field to `EventDto`**

Four spots, each directly below the `departureAt` line:

constructor: `required this.spotifyPlaylistUrl,`

`fromMap`: `spotifyPlaylistUrl: map['spotify_playlist_url'] as String?,`

field declaration: `final String? spotifyPlaylistUrl;`

`toCompanion`: `spotifyPlaylistUrl: Value<String?>(spotifyPlaylistUrl),`

- [ ] **Step 5: Extend the db round-trip test**

In `agenda_test.dart`, test `'database upsert + read round-trips'`: add to the `CachedEventsCompanion.insert(...)` call (below `notes:`):

```dart
        spotifyPlaylistUrl: const Value<String?>(
          'https://open.spotify.com/playlist/abc',
        ),
```

and to the assertions:

```dart
    expect(
      row.spotifyPlaylistUrl,
      equals('https://open.spotify.com/playlist/abc'),
    );
```

- [ ] **Step 6: Run mobile tests — verify green**

```bash
cd /d/kulturniprehled/apps/mobile
flutter test
```

Expected: all pass (9+).

- [ ] **Step 7: Commit**

```bash
cd /d/kulturniprehled
git add apps/mobile
git commit -m "feat(mobile): cache spotify_playlist_url (drift v10)"
```

---

### Task 4: Mobile — "Playlist na Spotify" link on the detail screen

**Files:**
- Modify: `apps/mobile/lib/features/events/event_detail_screen.dart` (`_EventDetailBody` children ~line 262, new widget next to `_VenueSection` ~line 407)
- Create: `apps/mobile/test/event_detail_test.dart`

- [ ] **Step 1: Write the failing widget test**

`EventDetailScreen` reads `GoRouterState.of(context)`, so pump it inside a minimal `GoRouter`. Back it with the real repository over the in-memory db (same helper agenda_test uses):

```dart
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kp_mobile/data/drift/database.dart';
import 'package:kp_mobile/features/events/event_detail_screen.dart';

import 'helpers/in_memory_db.dart';

Future<void> _insertEvent(KpDatabase db, {String? spotifyPlaylistUrl}) async {
  final DateTime now = DateTime.now().toUtc();
  await db.upsertEvent(
    CachedEventsCompanion.insert(
      id: 'evt-1',
      workspaceId: 'ws-1',
      title: 'Sokolov',
      category: 'concert',
      startsAt: now.add(const Duration(days: 7)),
      endsAt: const Value<DateTime?>(null),
      venueTimezone: const Value<String?>('Europe/Prague'),
      status: 'planned',
      source: 'manual',
      notes: const Value<String?>(null),
      spotifyPlaylistUrl: Value<String?>(spotifyPlaylistUrl),
      version: 1,
      updatedAt: now,
      deletedAt: const Value<DateTime?>(null),
      cachedAt: now,
    ),
  );
}

Widget _app(KpDatabase db) {
  final GoRouter router = GoRouter(
    initialLocation: '/event/evt-1',
    routes: <RouteBase>[
      GoRoute(
        path: '/event/:id',
        builder: (BuildContext context, GoRouterState state) =>
            const EventDetailScreen(eventId: 'evt-1'),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[kpDatabaseProvider.overrideWithValue(db)],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUpAll(() async => initializeDateFormatting('cs'));

  testWidgets('shows playlist link when the event has one', (tester) async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    await _insertEvent(
      db,
      spotifyPlaylistUrl: 'https://open.spotify.com/playlist/abc',
    );

    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();

    expect(find.text('Playlist na Spotify'), findsOneWidget);
  });

  testWidgets('hides playlist link when the event has none', (tester) async {
    final KpDatabase db = buildInMemoryDatabase();
    addTearDown(db.close);
    await _insertEvent(db);

    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();

    expect(find.text('Playlist na Spotify'), findsNothing);
  });
}
```

If `pumpAndSettle` times out on the cover-image shimmer, replace it with `await tester.pump(const Duration(seconds: 1));` — same workaround the project already notes for animated screens.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /d/kulturniprehled/apps/mobile
flutter test test/event_detail_test.dart
```

Expected: first test FAILS (`Playlist na Spotify` not found); second passes.

- [ ] **Step 3: Add the link to `_EventDetailBody`**

In the first padded `Column` (the one that ends with the `_NotesText` block, ~line 262), append after the notes entry:

```dart
              if (event.spotifyPlaylistUrl != null &&
                  event.spotifyPlaylistUrl!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 20),
                _PlaylistLink(url: event.spotifyPlaylistUrl!),
              ],
```

Add the widget next to `_VenueSection` (mirrors its underlined "Mapa" link style):

```dart
/// "Playlist na Spotify" row. Same underlined-link treatment as the Mapa
/// launcher in _VenueSection; opens the playlist in the Spotify app/browser.
class _PlaylistLink extends StatelessWidget {
  const _PlaylistLink({required this.url});

  final String url;

  Future<void> _open() async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.music_note_outlined, size: 18, color: Colors.black),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _open,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: Text(
              'Playlist na Spotify',
              style: TextStyle(
                fontFamily: 'StackSansHeadline',
                fontWeight: FontWeight.w600,
                fontSize: 12,
                letterSpacing: 0.48,
                color: Colors.black,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run the widget tests — verify both pass**

```bash
cd /d/kulturniprehled/apps/mobile
flutter test test/event_detail_test.dart
```

Expected: 2 passed.

- [ ] **Step 5: Run the full mobile gate**

```bash
cd /d/kulturniprehled/apps/mobile
dart format --output=none --set-exit-if-changed . && flutter analyze --fatal-infos --fatal-warnings && flutter test
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
cd /d/kulturniprehled
git add apps/mobile
git commit -m "feat(mobile): playlist link on event detail screen"
```

---

### Task 5: Skill — Spotify playlist step + credential docs

**Files:**
- Modify: `skills/ticket-parser/SKILL.md` (new step 8.5 between steps 8 and 9; edits to steps 10 and 11; one line in Notes)
- Modify: `skills/ticket-parser/README.md` (one-time Spotify app setup)

No automated tests — the skill is prose executed by Claude; verification is the manual E2E in Task 6.

- [ ] **Step 1: Add the one-time setup to `README.md`**

Append under Prerequisites:

````markdown
- One-time Spotify Web API setup (for the concert-playlist step):
  1. Create an app at <https://developer.spotify.com/dashboard> —
     name `Kulturni Prehled`, redirect URI `http://127.0.0.1:8888/callback`.
  2. Authorize once in a browser (replace `$CLIENT_ID`):
     `https://accounts.spotify.com/authorize?client_id=$CLIENT_ID&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback&scope=playlist-modify-public%20ugc-image-upload`
     and copy the `code` query param off the redirect URL.
  3. Exchange the code for a refresh token:
     ```bash
     curl -sS -X POST https://accounts.spotify.com/api/token \
       -u "$CLIENT_ID:$CLIENT_SECRET" \
       -d grant_type=authorization_code -d code="$CODE" \
       -d redirect_uri=http://127.0.0.1:8888/callback | jq -r .refresh_token
     ```
  4. Store all three in 1Password item `Spotify Web API (Kulturni Prehled)`
     with fields `client_id`, `client_secret`, `refresh_token`.
````

- [ ] **Step 2: Insert step 8.5 into `SKILL.md`**

Insert between step 8 (costs) and step 9 (Drive), verbatim:

````markdown
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
````

- [ ] **Step 3: Edit step 10 (calendar description)**

In the `description:` template of step 10, add after the `🚌 Odjezd…` line:

```
🎧 Playlist: $PLAYLIST_URL
```

(plus a sentence under the template: "Omit the line when `PLAYLIST_URL` is empty — non-concert events and Spotify failures.")

- [ ] **Step 4: Edit step 11 (report) and Notes**

Step 11 — extend the Czech summary sentence with: `"…kalendář hotový.
Playlist na přípravu: {PLAYLIST_URL}."` (omit when empty).

Notes section — add one bullet:

```markdown
- Spotify Web API credentials live in 1Password item
  `Spotify Web API (Kulturni Prehled)` (`client_id`, `client_secret`,
  `refresh_token`); scopes `playlist-modify-public ugc-image-upload`.
  One-time setup in README.md. The claude.ai Spotify MCP is NOT a
  substitute — it cannot add tracks to an existing playlist.
```

- [ ] **Step 5: Commit**

```bash
cd /d/kulturniprehled
git add skills/ticket-parser
git commit -m "feat(skills): build spotify concert playlist during ticket ingest"
```

---

### Task 6: Manual E2E + PR

- [ ] **Step 1: One-time Spotify credential setup**

Follow the new README section (Task 5 step 1) — requires Petr in the loop
(browser authorize). Verify:

```bash
op item get 'Spotify Web API (Kulturni Prehled)' --fields label=client_id --reveal | head -c8
```

Expected: prints the first 8 chars of the client id.

- [ ] **Step 2: Manual E2E on a real (or replayed) ticket**

Run `/kulturni-prehled-ingest` on a concert PDF and verify:
1. playlist exists on Spotify, name `KP • <date> • <title> — <venue>`, public, cover set;
2. tracks match the program (or latest album when no program);
3. `GET /v1/events/$EVENT_ID` shows `spotify_playlist_url`;
4. re-run the playlist step → same playlist updated, **no duplicate**;
5. mobile app after sync shows "Playlist na Spotify" on the detail screen and the link opens Spotify;
6. calendar event description carries the `🎧 Playlist:` line.

- [ ] **Step 3: Open the PR**

```bash
cd /d/kulturniprehled
git push -u origin feat/spotify-concert-playlists
gh pr create --title "feat: Spotify concert playlists from ticket ingest" --body "$(cat <<'EOF'
## Summary
- ingest skill builds a public per-concert Spotify playlist (program-based tracks, performers' recording preferred; latest album fallback) — Web API via curl, idempotent via the URL stored on the event
- new `events.spotify_playlist_url` (migration 0013) flowing through schemas, create handler and the sync payload
- mobile: drift v10 column + "Playlist na Spotify" link on the event detail screen
- calendar event description gets a `🎧 Playlist:` line

Spec: docs/superpowers/specs/2026-06-03-spotify-concert-playlists-design.md

## Test plan
- [ ] backend gate: ruff + black + mypy + pytest (new: field round-trip, sync payload)
- [ ] mobile gate: format + analyze + flutter test (new: detail-screen link shown/hidden)
- [ ] manual E2E per plan Task 6

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: After merge — deploy + handover note**

Backend changed → after merging, run the deploy + smoke test from CLAUDE.md
(`ssh petronijus@192.0.2.101 '/opt/kp/infra/deploy/upgrade.sh'`, then
`curl https://kulturniprehled.example.com/healthz`), and add a session entry
to `docs/handover.md` describing the feature + the new 1Password item.
