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
metadata, cost row, event notification, …) writes a `change_log` row in the same DB
transaction. The shape is:

```
change_log
  seq         bigserial primary key
  entity_type text                  -- 'event' | 'watchlist_item' | 'notification' | …
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
GET /v1/sync?since=<seq>&limit=<n>          # limit 1–1000, default 500
→ {
    "changes": [ { "seq": …, "workspace_id": …, "entity_type": …,
                   "entity_id": …, "op": "upsert"|"delete",
                   "payload": …, "actor_id": …, "created_at": … }, … ],
    "next_seq": …,
    "has_more": bool,
    "server_time": "<ISO 8601, UTC>"
  }
```

`server_time` is the server's clock when it built the page. The client
compares notification `deliver_after` against it, never against its own
clock, so a phone running fast cannot show a notification that is still
collecting merges (section 5). It is read from the database clock
(`clock_timestamp()`) **before** the `change_log` read, so a merge that
commits after the page's snapshot is never judged against a clock that
already passed its deadline.

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
   Body: { "operations": [ { "op_id": …, "entity": …,
                             "op": …, "entity_id": …,
                             "base_version": …, "payload": … }, … ] }
   → { "results": [ { "op_id": …, "status": …, "entity_id": …,
                       "version": …, "seq": …,
                       "current_version": …, "error": … } ] }
   ```
   `entity` is `event`, `watchlist_item` or `notification`; `status` is
   `applied`, `conflict`, `not_found`, `invalid` or `forbidden`. The
   appliers are the `_APPLIERS` table in
   `apps/api/src/kp_api/sync/service.py`. `entity` (≤ 40 chars) and `op`
   (≤ 20) are free strings on the wire: a pair the server does not know
   is one `invalid` result for that op, not a `422` for the whole batch,
   so a newer app talking to an older API does not wedge its outbox.
4. `op_id` is the **idempotency key**. The server checks for an existing
   entry in an `applied_ops(op_id)` table before applying; replays
   return the original result without mutating anything. This is what
   makes retries safe — flaky network, partial 500s, the client
   re-posting after a crash, all converge to the same outcome.
5. A network failure or a `5xx` leaves the whole batch pending for the
   next trigger. A `400`/`422` for the whole batch means the server could
   not parse one of its ops; the client then resends the batch **op by
   op**, and an op rejected on its own is **dropped** (logged, recorded
   with `markPendingError`, reported to Sentry) so it cannot block every
   later edit (`_send` in `outbox_controller.dart`).

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

## 5. Event notifications

Since 2026-10-26 the **server** decides what is worth a notification on
both phones; the phone only renders and shows it. Server impl:
`apps/api/src/kp_api/notifications.py` (table `event_notifications`,
migration `0019`). Mobile impl: `_deliverDueNotifications` in
`sync_controller.dart` and `features/notifications/event_notification.dart`.

### What produces one

| Trigger | `kind` | Due (`deliver_after`) |
|---|---|---|
| An event is created (REST or outbox) | `event_created` | now + 2 min |
| An event's `venue_address` or `notes` change | `event_changed`, `changes` ⊆ `venue`, `program` | now + 2 min |
| A member asks: `POST /v1/events/{id}/notifications` or an outbox op | `manual` | now, if nothing is pending |

"Now" is the database clock (`clock_timestamp()`), read after the event
row is locked, never the API container's clock.

- Only `venue_address` and `notes` are watched (`WATCHED_FIELDS`). A
  whitespace-only edit, or `""` versus `null`, is not a change. Title,
  times, cover, venue image and playlist edits stay silent; a member who
  wants them announced sends a manual one.
- **Coalescing.** While a notification for the event is pending with
  more than `MERGE_MARGIN` (15 s) to go (`deliver_after > now + 15 s`),
  every further reason merges into that row instead of adding a second
  one: the strongest `kind` wins (`event_created` > `manual` >
  `event_changed`), `changes` are unioned, a new `message` replaces the
  old one, `version` goes up. A manual request that merges waits for the
  pending row's `deliver_after`. Within the last 15 s a new notification
  is created instead: a merge decided that close to the deadline could
  commit after a phone had already pulled a page whose `server_time`
  passed it and shown the earlier version, and the merged reason would
  arrive late or not at all. (The phone's re-show of newer versions,
  below, is the second guard.)
- `announce()` locks the event row (`SELECT deleted_at … FOR UPDATE`), so
  two concurrent requests serialize. If the event was deleted meanwhile
  it raises `EventGone`: the REST endpoint answers `404`, the outbox op
  `not_found`.
- Deleting an event soft-deletes its pending notifications.
- Every create, merge and withdrawal writes a `change_log` row with
  `entity_type='notification'`; the payload is
  `serialize_notification()` in `sync/changelog.py` (`id`,
  `workspace_id`, `event_id`, `kind`, `changes`, `message`, `created_by`,
  `deliver_after`, `version`, timestamps, `deleted_at`). The mobile
  `EventNotificationDto` mirrors it.

The outbox form of a manual request:

```
{ "op_id": …, "entity": "notification", "op": "create",
  "entity_id": "<event id>", "payload": { "message": "…" } }   # message optional, ≤ 500 chars
```

The result's `entity_id` is the notification's id (the pending row's when
it merged). A deleted event answers `not_found`. `op_id` idempotency
means a retried request never notifies twice.

### What the phone does

After every pull the app caches notification rows in the drift
`CachedNotifications` table (schema 11) and then:

1. **First sync of a fresh install** (cursor was 0): marks every
   notification that is already due as shown without showing it, so the
   history is not replayed. Pending ones stay and are shown once due.
2. Otherwise it shows every row that is not deleted, due on the server
   clock (`deliver_after <= server_time` of the last page) and whose
   current `version` this device has not shown (`shownVersion` null or
   lower), oldest first. A newer version of a row already shown is shown
   again under the same platform id, replacing it; `onlyAlertOnce` keeps
   a foreground and a background sync racing on the same row from
   alerting twice. The author's own phone shows it too.
3. Text and cover come from the event's **current** cached state at
   delivery time (`renderEventNotification`), so a cover PATCHed inside
   the 2-minute window is in the notification.
4. A row whose event is missing or deleted, or that is overdue by more
   than 24 h (the phone was offline for days), is dropped: marked shown
   and logged, with its last show error if it had one.
5. A row whose `show()` throws stays unshown: `attempts` goes up,
   `lastError` keeps the error, it is logged and sent to Sentry, and the
   next sync retries it. `shownVersion`, `attempts` and `lastError` are
   local-only; the sync upsert never writes them.

Delivery latency is "the next sync": app open or resume, pull-to-refresh,
else the 30-min background job (on iOS BGTaskScheduler picks the time
itself). There is no push; see
[architecture.md](./architecture.md#push-deliberately-omitted).

Tests that move with this contract: `apps/api/tests/test_notifications.py`,
`apps/api/tests/test_sync.py`, `apps/mobile/test/event_notification_test.dart`,
`apps/mobile/test/notification_reschedule_race_test.dart`,
`apps/mobile/test/event_detail_test.dart`, `apps/mobile/test/outbox_test.dart`.

Release order: the API ships before the app ([release.md](./release.md)).
