# Architecture

High-level architecture for Kulturní Přehled. The system is intentionally
small — two users, a single shared workspace, one Proxmox VM — and the
boundaries below reflect that scope rather than a generic
production-grade microservice template.

## Components

```
[Mobile iOS/Android] ──HTTPS──┐
                              │
[Claude skill on desktop] ────┼──> [Cloudflare Tunnel] ──> [kulturniprehled.example.com] FastAPI
                              │                       └──> [kulturniprehled-tickets.example.com] MinIO (signed URLs)
                              │
                              └── (no APNs / FCM — see "Push, deliberately omitted" below)

FastAPI ──> PostgreSQL  (events, watchlist, sync log, users, costs, recommendations)
        ──> MinIO       (ticket PDFs, posters, venue photos)
        ──> Anthropic   (ticket parsing, future embeddings)
        ──> Google Cal  (one-way sync, idempotent via extendedProperties.kp_event_id)
```

## Why this shape

- **Self-hosted on Proxmox** — data sovereignty, no SaaS bill, full
  control of upgrade cadence and the data lifecycle.
- **Single shared workspace** — Petr + Běla see the same agenda, the same
  watchlist, the same stats. A real multi-tenant model is unnecessary
  for the foreseeable horizon and would add accidental complexity
  (RBAC, per-user keyspace, shared-folder edge cases). The schema does
  carry `user_id` columns where appropriate so a future split is not
  blocked.
- **Offline-first mobile** — tickets must be readable at venues where
  signal is unreliable. The app pre-caches every upcoming event's
  cover image and ticket PDF to disk after each sync, and reads from
  disk first on every render. See [sync.md](./sync.md) for the
  caching layer's invariants.
- **One-way Google Calendar sync** — Google Calendar cannot represent
  tickets, costs or ratings; round-tripping would silently lose data
  on the Google side and then re-import as stubs. We push, never pull.

## Push, deliberately omitted

The original plan reserved a `NotificationProvider` abstraction with APNs
+ FCM backends. We dropped both during M11 in favour of:

- A 30-minute periodic background sync via WorkManager (Android) /
  BGTaskScheduler (iOS). Pulls server changes, primes the offline cache,
  exits.
- Local notifications scheduled by the app itself for upcoming events
  (via `flutter_local_notifications`). No server push needed — the
  client knows when its own events start.

Trade-off: server-pushed alerts (e.g. "a new event was just added by
the other user") arrive on the next 30-min poll instead of instantly.
For two users sharing one agenda, that latency is invisible; the
operational simplicity (no APNs cert renewal, no FCM project, no
per-device push token table) is worth it.

## Sync layer

Implementation: `apps/api/src/kp_api/sync/` on the server,
`apps/mobile/lib/features/sync/` on the client.

The contract is documented in [sync.md](./sync.md). Cliffnotes:

- Server `change_log.seq` is a monotonic `bigserial` cursor — never
  decreased, never set manually. Client pulls `GET /v1/sync?since=<seq>`.
- Client writes go through a drift `pending_ops` outbox with a
  client-generated `op_id` UUID. `POST /v1/sync/apply` is idempotent on
  that key, so retries are safe.
- Conflict resolution: server-assigned `version` on every mutable row;
  client sends the version it observed, server returns a conflict if
  the row has moved on. UI shows a "keep yours / use server" dialog.
- Soft-delete only: API sets `deleted_at`, never `DELETE`. A nightly
  batch purges tombstones older than 90 days.

## Offline cache layer (M11)

After every successful `pullChanges()`, `OfflineCacheService.refresh()`
walks the local agenda and:

1. Downloads every upcoming event's cover + venue images to
   `<app-docs>/cache/img/<sha1(url)>` if not already on disk. Records
   each download in the drift `CachedImages` table.
2. For every upcoming event that has tickets, fetches a fresh signed
   URL from `GET /v1/tickets/{id}/url`, downloads the binary to
   `<app-docs>/cache/tickets/<ticket-id>.<ext>`, records the local
   path on the drift `Tickets` row.
3. Garbage-collects: any cached image / ticket file belonging to an
   event whose end time is more than a day in the past gets deleted
   from disk. Shared cover URLs across events are detected so we
   don't delete what's still needed.

All UI widgets that render event imagery use `LocalFirstImage`, which
resolves the cached file via SHA-1 of the URL and falls back to
`Image.network` on a cache miss. Same pattern for tickets — the viewer
opens the local file directly, never touches MinIO at render time.

## Background sync (M11)

A single WorkManager job named `kp-bg-sync` is registered at app boot.
It fires every 30 minutes with `NetworkType.connected` constraint and a
5-minute initial delay (so a fresh install doesn't fight its cold-start
sync). The job runs in a separate isolate, spins up a fresh
`ProviderContainer`, calls `pullChanges()` + `OfflineCacheService.refresh()`,
and tears the container down before returning.

On iOS the same plugin uses BGTaskScheduler; the identifier
`kp-bg-sync` is registered in `AppDelegate.swift` and declared in
`Info.plist` under `BGTaskSchedulerPermittedIdentifiers` +
`UIBackgroundModes`. iOS background scheduling is best-effort — the OS
chooses when to wake the app based on its own heuristics — but typical
behaviour gives us a refresh within an hour or two of the requested
cadence, which is fine for our use case.

## Brand assets pipeline

`assets-source/brand/` holds the user-authored masters
(`kp_logo_master.png`, `kp_launcher_master.png`, `kp_notif_master.png`,
all 1024×1024 PNG). Downstream artefacts — the in-app logo, Android
`mipmap-*/ic_launcher.png` + `drawable-*/ic_stat_notify.png`, iOS
`AppIcon.appiconset` — are **regenerated from those masters** when the
masters change. The generators never invent or paint pixels; they only
resize and (for the iOS appicon) flatten alpha onto an opaque
background. See `assets-source/brand/README.md` for the contract.

## Proactive recommendations (M12)

The M12 slot turned out **not** to be a server-side worker writing
into the `recommendations` table. Instead it lives entirely in
`skills/` as a Claude Code skill suite, scheduled via `/schedule`.
The trade-off: server-side cron would have meant scrapers + LLM API
calls + email composition all in Python; the skill approach reuses
Claude Code's MCP servers (Spotify, google-workspace) and WebFetch
for free, and Claude itself does the ranking step.

Topology:

```
/schedule (Mon 08:00) ─→ /kulturni-prehled (aggregator)
                            │
                            ├─→ Skill /klasika-expert     → /tmp/kp-digest-CW<n>/klasika.json
                            ├─→ Skill /elektronika-expert → elektronika.json
                            ├─→ Skill /divadlo-expert     → divadlo.json (future)
                            └─→ Skill /film-expert        → film.json (future)
                                              │
                                              ▼
                            merge + balance + spacing + Gmail send
```

Per-expert candidate gathering is a **hybrid** — static bash
scrapers for permanent sources (orchestras, theatre companies),
LLM-driven WebFetch for dynamic sources (festivals, club programs).
The aggregator owns cross-domain rules: balance signal from the KP
API event history, ~1-event-per-week spacing with `season_event`
exceptions, global cap of ~5 picks. Every expert is independently
runnable (`/klasika-expert` in chat returns JSON without sending);
the aggregator is the only skill that emails.

The `recommendations` table in the DB schema is **unused** — the
weekly digest goes straight to inbox; if Petr buys a ticket it
flows back via the existing `kulturni-prehled-ingest` skill. No
server-side recommendation storage needed.

Implementation: `skills/kulturni-prehled/SKILL.md` + per-expert
skills + `skills/<expert>/preferences.md` for hand-edited taste
profiles. Operator docs in `skills/kulturni-prehled/README.md`.

## To be expanded

- Sequence diagrams for: ticket ingestion via skill, offline edit +
  reconcile, background sync wake, weekly recommendation digest.
- Operational diagrams: backup, restore drill, tunnel topology.
