# Sync

The sync subsystem is split into three layers, in order of how much you
have to think about them when reading the code:

1. **Server change log** — `change_log` table, `GET /v1/sync` endpoint.
   Authoritative ordering of every server-side mutation.
2. **Client outbox** — drift `pending_ops` table, `POST /v1/sync/apply`
   endpoint. Offline edits queue up here and reconcile on the next
   network window.
3. **Offline cache** — drift `CachedImages` table + on-disk files under
   `<app-docs>/cache/`. Materialises images and tickets so the UI never
   waits on the network at render time.

Server impl: `apps/api/src/kp_api/sync/`. Mobile impl:
`apps/mobile/lib/features/sync/`.

## 1. Server change log

Every mutation to a syncable entity (event, watchlist item, ticket
metadata, cost row, …) writes a `change_log` row in the same DB
transaction. The shape is:

```
change_log
  seq         bigserial primary key
  entity_type text                  -- 'event' | 'watchlist_item' | …
  entity_id   uuid
  op          text                  -- 'upsert' | 'delete'
  payload     jsonb                 -- entity snapshot at time of write
  by_user     uuid references users(id)
  at          timestamptz default now()
```

`seq` is the monotonic cursor mobile clients consume. **Invariants**:

- `seq` is **never decremented**, **never reused**, **never set
  manually**. The DB assigns it.
- Every mutation that reaches mobile must produce exactly one
  `change_log` row. If you add a new entity type, you also wire its
  service into `apps/api/src/kp_api/sync/changelog.py` and grow the
  client-side dispatcher in `sync_controller.dart`.
- Soft-delete only — `op='delete'` rows still carry the entity's last
  payload so a client that missed the row entirely can still build a
  tombstone locally. The actual row is updated with `deleted_at = now()`,
  not removed. A nightly purge job (see `apps/api/src/kp_api/cli.py`)
  drops rows whose `deleted_at` is older than 90 days.

### Pull

```
GET /v1/sync?since=<seq>&limit=<n>
→ {
    "entries": [ { "seq": …, "entity_type": …, "entity_id": …,
                   "op": …, "payload": …, "version": … }, … ],
    "next_seq": …,
    "has_more": bool
  }
```

The client stores the highest `seq` it has applied in the drift
`sync_cursor` row and re-issues with `since=cursor` on the next pull.
The server returns up to `limit` rows in ascending `seq` order; the
client loops on `has_more=true` until caught up.

The mobile sync controller calls `pullChanges()` on:
- App resume / cold start (`SyncController.start()`).
- Manual pull-to-refresh on the agenda.
- The 30-min WorkManager / BGTaskScheduler background job.

## 2. Client outbox + write path

Local edits never call the API synchronously. They go through the
outbox so a tap is always instant and a flight-mode user can still
queue up writes:

1. The UI calls e.g. `eventService.upsertEvent(draft)`.
2. The service writes the entity to drift **and** appends a row to
   `pending_ops`:
   ```
   pending_ops
     op_id       text primary key   -- client-generated UUID v4
     entity_type text
     entity_id   text
     op          text               -- 'upsert' | 'delete'
     payload     text               -- JSON snapshot
     version     integer            -- the version the client observed
     attempts    integer default 0
     last_error  text nullable
   ```
3. `OutboxPusher` (running on a network-availability stream) batches
   pending rows and posts them to `POST /v1/sync/apply`:
   ```
   POST /v1/sync/apply
   Body: { "ops": [ { "op_id": …, "entity_type": …,
                       "entity_id": …, "op": …,
                       "payload": …, "version": … }, … ] }
   → { "results": [ { "op_id": …, "status": "applied"|"conflict",
                       "server_version": …, "server_payload": … } ] }
   ```
4. `op_id` is the **idempotency key**. The server checks for an existing
   entry in an `applied_ops(op_id)` table before applying; replays
   return the original result without mutating anything. This is what
   makes retries safe — flaky network, partial 500s, the client
   re-posting after a crash, all converge to the same outcome.

### Conflicts

A row is in `conflict` state when the client's observed `version`
doesn't match the server's current `version`. The outbox keeps the
pending op around (status flips to "conflict"), the UI shows a banner
on that entity, and tapping it pops a "**Use mine** / **Use server**"
dialog. The user's choice writes a new pending op (`version` ← the
fresh server version, payload ← either local or server) which then
flows through `/v1/sync/apply` normally.

### Why not CRDTs

Two-user, low-write-contention shared agenda. Designed for the case
where Petr enters a concert in the morning and Běla edits its notes
that evening — the conflict surface is real but rare enough that a
human-resolved dialog beats every CRDT's correctness/UX trade-off.
We are not building Notion.

## 3. Offline cache layer (M11)

The sync layers above keep **structured data** in step. The offline
cache keeps **binary content** (cover images, venue photos, ticket
PDFs) on disk so the UI can render without a round-trip.

After every successful `pullChanges()`, `OfflineCacheService.refresh()`
runs (unawaited from the foreground sync — see
`sync_controller.dart:postPull`):

1. **Image cache.** For every event with `start_at >= now()`, ensure
   `cover_url` (and any venue image URLs) are on disk under
   `<app-docs>/cache/img/<sha1(url)>`. The drift `CachedImages` table
   maps `urlHash → localPath` for fast lookup. Downloads use a raw
   Dio client (no auth — images are publicly signed MinIO URLs, scoped
   short enough that we don't worry about cache-side leakage).

2. **Ticket cache.** For every ticket on every upcoming event, call
   `GET /v1/tickets/{id}/url` to get a fresh signed download URL,
   download to `<app-docs>/cache/tickets/<ticket-id>.<ext>`, and
   write the path onto the drift `Tickets` row. The ticket viewer
   opens the local file directly; MinIO is hit at most once per
   ticket per device.

3. **Garbage collection.** Walk `Events` where `end_at < now() - 1d`
   and collect every cached URL hash referenced from their covers /
   venue images. Diff against `CachedImages.urlHash`; any hash whose
   referencing events are *all* past gets its on-disk file deleted
   and its drift row removed. Same logic for ticket files via
   `Tickets.localPath`. The 1-day grace window covers late-night
   events that "end" technically before midnight but the user might
   still re-open in the morning.

The `LocalFirstImage` widget (and the equivalent ticket-opening code)
encapsulates the cache miss fall-through: if the resolved local path
exists, render `Image.file`; otherwise render `Image.network` with the
original URL and let the next sync's cache-prime catch it.

## 4. Background sync

`apps/mobile/lib/features/sync/background_sync.dart` registers one
periodic WorkManager job (`kp-bg-sync`, 30 min, `NetworkType.connected`,
5-min initial delay). The callback runs in a fresh isolate, instantiates
its own `ProviderContainer`, runs `pullChanges()` + an awaited
`OfflineCacheService.refresh()`, and disposes everything before
returning. On iOS the federated `workmanager_apple` plugin routes the
same callback through BGTaskScheduler. The task identifier
`kp-bg-sync` is registered in `AppDelegate.swift` and listed in
`Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.

Failures inside the callback are swallowed — we explicitly do **not**
return `false` (which would ask WorkManager to retry with exponential
backoff). The next periodic firing tries again.
