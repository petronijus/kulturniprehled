# API reference

The canonical reference is the OpenAPI document exposed at
`GET /openapi.json` (and a Swagger UI at `GET /docs`).

This file collects out-of-band notes that do not fit cleanly into
OpenAPI: authentication flow, sync semantics, ticket signed-URL flow,
and the operational quirks worth knowing before integrating against
the API.

## Endpoints, by area

| Path prefix          | What                                                    | Source |
|----------------------|---------------------------------------------------------|--------|
| `/healthz`           | Liveness probe; returns `{"status":"ok",…}`            | `api/v1/healthz.py` |
| `/v1/auth/*`         | Google OAuth callback, refresh, logout, list PATs      | `api/v1/auth.py` |
| `/v1/events/*`       | Event CRUD + listings (agenda, calendar window)        | `api/v1/events.py` |
| `/v1/watchlist/*`    | Watchlist items + reordering                           | `api/v1/watchlist.py` |
| `/v1/tickets/*`      | Ticket CRUD + signed download URL                      | `api/v1/tickets.py` |
| `/v1/costs/*`        | Per-event cost rows                                    | `api/v1/costs.py` |
| `/v1/stats/*`        | Year-in-review aggregates                              | `api/v1/stats.py` |
| `/v1/sync/*`         | Change-log pull + outbox apply                         | `api/v1/sync.py` |
| `/v1/season/*`       | Season planner: plans, candidate pool (bulk upsert + plan state), scenarios (upsert/apply), novelty cursor, shared-calendar view, programme media links | `api/v1/season.py` |
| `/app`               | Season-planner SPA (static bundle, history-API fallback, relaxed CSP). **Home-only + login-less**: with `WEB_PUBLIC=false` (default) Cloudflare-proxied requests get 404 — reachable only via LAN / Tailscale | `web.py` + `web/dist` |

`GET /v1/season/calendar?from=&to=` is the one place the shared household
calendar (Kocourek&Prdelčička) is read and classified. The API fetches its
secret iCal address (`CALENDAR_ICS_URL`, cached for
`CALENDAR_CACHE_TTL_SECONDS`), expands recurrence over the window and
answers with `blocked_days` + `conflicts` — the exact shape
`skills/kulturni-sezona/bin/kp_validate.py` consumes as `blocked.json` —
plus `entries`, one per day an event occupies, which the planner grid
renders. Classification canon: all-day spans block every covered date
(DTEND exclusive); a title matching
`(dovolen|holiday|pryč|away|cottage|šumperák|chalup)` blocks every day it
spans; every other timed event becomes a conflict window. An unconfigured
or unreachable feed answers `200` with `available: false` (a stale cached
feed is preferred over an empty one), so no consumer ever hard-fails on
the calendar. The window is capped at 400 days.

The pool ingest enforces a **venue veto** (`SEASON_VENUE_VETO`, comma
separated): a candidate whose `venue` or `source_name` contains a vetoed term
is refused on arrival (`vetoed` in the response), and pool rows already stored
at such a venue are soft-deleted on every ingest (`purged`). The veto is
therefore retroactive — adding a venue to it cleans the pool up on the next
scrape, and `PUT …/pool` with `{"items": []}` applies it immediately without
running one. The experts veto the same venues while scraping
(`skills/*/preferences.md`); this is the backstop that holds regardless of
which expert or run produced the candidate.

`GET /v1/season/holidays?from=&to=` marks Czech public holidays in the
planner grid, from the public feed in `HOLIDAYS_ICS_URL` (defaulted, not a
secret, cached for a day). It reuses the same fetch/expand pipeline and
reduces it to one titled day per date. Deliberately a separate endpoint
from `/calendar`: the household feed is a secret and the holiday feed is
not, and one being unreachable must not blank the other. Holidays are a
visual mark only — they never block a day and never enter `conflicts`.

`GET|PUT /v1/season/program-links` is the piece→recording map behind the
planner's ▶ buttons. A row is keyed by the **folded piece identity**
(`author|work` lowercased, diacritics stripped, everything else collapsed
to single spaces — `kp_api/domain/program_key.py`, mirrored in the SPA's
`domain/programKey.ts`, both tested against the same fixtures). Keying by
piece rather than by candidate is deliberate: a season's orchestras play
the same works, so each is resolved once, and a pool upsert — which
rewrites a candidate's `program` wholesale — cannot wipe the links.

The upsert is additive per service: an item carrying only `spotify_url`
leaves a stored `youtube_url` alone, so the resolver (`/program-links`
skill, which searches Spotify with Petr's own refresh token — the API holds
no Spotify credentials) can run in several passes. Items with no identity
or no link are counted as `skipped` rather than failing the batch. A piece
with no stored link is not broken in the planner: the ▶ falls back to a
Spotify search for `author work`.

Season endpoints are gated by the `season:read` / `season:write` PAT
scopes (interactive JWTs and unscoped PATs pass everywhere). With
`WEB_TRUSTED_LAN=true`, a request with no Authorization header that did
not come through the Cloudflare Tunnel is authenticated as the workspace
owner restricted to exactly these two scopes — that is how the login-less
planner talks to the API; every other endpoint still requires a token. Key
invariants: pool upsert is idempotent by `(season_id, dedup_key)` with a
server-side content hash (identical re-push bumps nothing) and never
touches the user-owned plan fields (`plan_status`, `plan_status_at`,
`note`, `first_seen_at`); exactly one season per workspace is `active`;
`novelty_ack_at` is a monotonic cursor for the weekly novelty routine.
The season tables are web-only — they do not participate in `/v1/sync`.

Full request/response schemas live in OpenAPI — fetch
`https://kulturniprehled.example.com/openapi.json` for prod, or
`http://localhost:18000/openapi.json` against the dev compose stack.

## Authentication

Two credential types, both presented as `Authorization: Bearer <token>`.

### Mobile + web — Google OAuth → JWT

```
[mobile]  POST /v1/auth/google
          Body: { id_token: "<google id_token>" }
   →      { access_token, refresh_token, expires_in: 900 }

[mobile]  POST /v1/auth/refresh
          Body: { refresh_token }
   →      { access_token, refresh_token, expires_in: 900 }
```

- `id_token` must be issued by the Google OAuth client whose ID is
  configured via `GOOGLE_OAUTH_CLIENT_ID`. The server validates the
  signature, audience and `email_verified` itself — it does not call
  Google's tokeninfo endpoint.
- The user's email must appear in `ALLOWED_EMAILS` (env var, comma-
  separated). Everything else is rejected with `401`.
- `access_token` lifetime is 15 minutes. `refresh_token` is a single-use
  opaque value stored hashed in `auth_refresh_tokens`. Each call to
  `/v1/auth/refresh` rotates it; the old token is marked `revoked` and
  reuse is detected (re-use → all refresh tokens for that user are
  burned and the user must re-auth).

### Headless — Personal Access Token (PAT)

For the Claude skill and any other long-running headless integration.
PATs are minted **server-side via the CLI**, not by any HTTP endpoint
— the API never returns one to a network caller:

```bash
./scripts/mint-pat.sh petr@example.com 'desktop-skill'
# wrapper around `docker compose exec api python -m kp_api.cli mint-pat …`
# Writes the token straight into 1Password (item
# "Kulturni Prehled API Token", field "credential"); it never lands
# on stdout, shell history, or another process's argv.
```

PATs do not expire. Revoke by deleting the matching row from
`auth_personal_tokens` (or rotating to a fresh token and removing the
old `1Password` value).

## Sync

See [sync.md](./sync.md) for the full algorithm. Quick reference of the
two endpoints:

```
GET  /v1/sync?since=<seq>&limit=<n>
POST /v1/sync/apply
     Body: { ops: [ { op_id, entity_type, entity_id, op, payload, version }, … ] }
     →    { results: [ { op_id, status: "applied"|"conflict", … } ] }
```

- `op_id` is the **idempotency key**. Retries on the same `op_id` are
  no-ops that return the original result.
- `version` is the row version the client observed when it built the
  op. If the server has moved on, the result is `conflict` and the
  server's current `payload` + `version` come back so the client can
  surface a "use mine / use server" choice.
- Soft delete only. `op="delete"` updates `deleted_at = now()`; the row
  still exists in the database for 90 days for clients that missed it.

## Ticket signed-URL flow

Tickets live in MinIO. The API never proxies binary content — it hands
out short-lived signed URLs and the client (or the offline cache pre-
warmer) downloads directly from MinIO.

```
GET /v1/tickets/{id}/url
→ { url: "https://kulturniprehled-tickets.example.com/...?X-Amz-Signature=...",
    expires_at: "2026-05-22T15:00:00Z" }
```

- The signed URL hostname is `MINIO_PUBLIC_ENDPOINT` (env var on the
  API container). SigV4 signs the request host, so the API uses a
  dedicated MinIO client bound to the public hostname for URL generation
  and a separate internal client for ops (bucket bootstrap, deletes).
- URLs are valid for 1 hour. The offline cache downloads them within
  seconds of issue so expiry is not a practical concern.
- Uploads go through `POST /v1/tickets` (multipart), which streams the
  payload server-side to MinIO. The Claude skill is the only writer
  today.

## Operational notes

- **Migrations** run on every API container start (`docker-entrypoint.sh`
  → `alembic upgrade head`). There is no separate migration step in
  the deploy flow.
- **The API is async-only.** Any new handler must use
  `AsyncSession` and never call sync DB methods from the request
  path. mypy strict enforces this at type level.
- **No webhooks consumed today** — reserved for a future scraper that
  ingests "what's on this week" feeds from venues.
- **Performance budgets**: any endpoint whose p95 grows past 200 ms gets
  treated as a bug. Eager-load via `selectinload`/`joinedload`; N+1
  queries are explicitly forbidden.
