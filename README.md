# Kulturní Přehled

Self-hosted cultural-event tracker for two users (Petr + Běla), with mobile
apps for Android and iOS and a Claude Code skill that ingests purchased
tickets and creates events automatically.

## Features

- Shared agenda of concerts, theatre, cinema and other cultural events —
  chronological list, monthly calendar, dedicated past-events view, and a
  per-event detail screen with cover art, venue photos, ticket PDFs, costs
  and notes.
- Shared watchlist (todo-style) of films, theatre and concerts to catch
  later, with 2-level nesting (e.g. "Godard" → individual films),
  drag-to-reorder, and 10-second polling so both devices stay in sync.
- Year-in-review statistics — total spend, visits by category, top venues,
  monthly distribution.
- LLM-powered ticket ingestion: drop a ticket file into Claude on the
  desktop and the event, metadata, transport details and the ticket itself
  appear on both phones — offline.
- **Offline-first mobile**: after each sync the app proactively pre-caches
  every upcoming event's cover image and ticket PDF onto the device, then
  garbage-collects past events. The agenda, detail screen, ticket viewer
  and calendar all read from disk first and fall back to the network only
  on cache misses. Tickets stay readable at venues without signal.
- **Background sync**: a 30-minute WorkManager (Android) / BGTaskScheduler
  (iOS) task pulls server changes and re-primes the cache while the app is
  closed, so the first launch on event day is already up-to-date. No FCM /
  APNs dependency — simpler ops, no push tokens to manage.
- One-way sync to a shared Google Calendar (idempotent via
  `extendedProperties.kp_event_id`).
- CZK cost tracking with year-in-review statistics.
- Offline edit queue: writes go into an outbox table and reconcile with
  the server when the network returns; version conflicts surface a
  "keep yours / use server" dialog.
- Local notifications for event start time, configurable per-event.
- Optional self-hosted GlitchTip / Sentry error reporting.
- Infrastructure prepared for a future proactive AI recommendations agent.

## Stack

- **Backend** — Python 3.12, FastAPI, SQLAlchemy 2.0 async, PostgreSQL 16,
  Alembic, MinIO (S3-compatible).
- **Mobile** — Flutter 3.44.0 (Android primary, iOS feature parity), drift
  (SQLite), Riverpod, go_router, Material 3, pdfrx, workmanager
  (federated), sensors_plus, flutter_local_notifications.
- **LLM** — Anthropic Claude API behind a `LLMProvider` abstraction.
- **Public access** — Cloudflare Tunnel, two subdomains
  (`kulturniprehled.example.com` for the API,
  `kulturniprehled-tickets.example.com` for MinIO signed URLs).
- **Auth** — Google OAuth2 (PKCE on mobile) + JWT (15 min) + refresh-token
  rotation with reuse detection. Personal access tokens for headless
  clients (the Claude skill).
- **Mobile release** — signed APK from GitHub Releases for Android (Pixel
  + Běla's phone sideload), TestFlight Internal Testing (group `Družina`)
  for iOS.

See [`CLAUDE.md`](./CLAUDE.md) for the development guide, including the
local pre-merge checklist, release procedure and iOS dev-sideload flow.

## Repository layout

```
apps/api/            FastAPI service
apps/mobile/         Flutter app
packages/            OpenAPI snapshot
skills/ticket-parser Claude Code skill source
assets-source/       master design assets — user-authored, repo of truth
  brand/             logo + launcher + notification icon masters; the
                     downstream PNG/AppIcon variants are regenerated from
                     these only when the masters change
infra/
  docker-compose.yml    dev stack (Postgres + MinIO + API)
  compose.prod.yml      prod overlay (cloudflared, hardened ports)
  compose.glitchtip.yml optional error-reporting overlay
  cloudflared/          tunnel config example
  deploy/               setup-vm.sh + upgrade.sh + README
  backup/               pg_dump, mc_mirror, restore-test, cron.example
docs/                Architecture, API, sync, deployment, handover notes
```

## Quick start (development)

Prerequisites:
- Docker and Docker Compose v2
- Python 3.12+ (only needed for running backend tests outside Docker)
- Flutter 3.44.0 (only needed for the mobile app)

```bash
cp .env.example .env
# Edit .env — at minimum:
#   GOOGLE_OAUTH_CLIENT_ID + SECRET (mine: 1Password "google petr-apps OAuth client")
#   ANTHROPIC_API_KEY              (mine: 1Password "Claude API Token")
#   ALLOWED_EMAILS                 (Petr + Běla)

docker compose --env-file .env -f infra/docker-compose.yml up -d
curl http://localhost:18000/healthz   # → {"status":"ok",...}
```

The dev stack publishes Postgres on `15432`, MinIO API on `19000`
(console `19001`) and the API on `18000` so it can co-exist with a system
Postgres/MinIO.

## Skill setup (desktop ingestion)

```bash
./scripts/mint-pat.sh petr@example.com 'desktop-skill'
# script pipes the JWT straight into 1Password — never to stdout
```

The skill itself lives in `skills/ticket-parser/`; symlink it into Claude
Code's skills directory once:

```bash
ln -sfn $(pwd)/skills/ticket-parser ~/.claude/skills/kulturni-prehled-ingest
```

## Testing

```bash
# Backend (testcontainers spins up Postgres + MinIO)
cd apps/api
uv sync --dev
uv run pytest

# Mobile
cd apps/mobile
flutter pub get
flutter test
```

See [`CLAUDE.md`](./CLAUDE.md) for the full pre-merge checklist (ruff,
black, mypy, dart format, flutter analyze).

## Production deployment

See [`infra/deploy/README.md`](./infra/deploy/README.md). TL;DR:

```bash
sh infra/deploy/setup-vm.sh        # one-shot bootstrap
# fill /opt/kp/.env, drop Cloudflare Tunnel creds in /etc/cloudflared
docker compose --env-file /opt/kp/.env \
               -f /opt/kp/infra/docker-compose.yml \
               -f /opt/kp/infra/compose.prod.yml \
               up -d
# Wire infra/backup/cron.example into /etc/cron.d/kp
```

For routine releases: `ssh deploy@kp-vm /opt/kp/infra/deploy/upgrade.sh`.

## Mobile release

- **Android** — local signed APK build, published to GitHub Releases. Petr
  + Běla install via browser from
  `https://github.com/petronijus/kulturniprehled/releases`. Procedure in
  [`CLAUDE.md`](./CLAUDE.md) under *Release procedure*.
- **iOS** — TestFlight Internal Testing (group `Družina`,
  auto-distribute on). Two release paths:
  - Local Mac with Xcode + app-specific password — original recipe in
    [`CLAUDE.md`](./CLAUDE.md) under *iOS release procedure (TestFlight)*.
  - Headless from any SSH-capable workstation via the Proxmox MacOS VM
    + App Store Connect API key. End-to-end recipe lives in
    [`docs/handover.md`](./docs/handover.md) under the 2026-05-22 session.

## Milestones

- **M0** Repo bootstrap.
- **M1** Backend foundation — Google OAuth + JWT refresh rotation + events CRUD.
- **M2** Sync API + `change_log` + outbox apply with idempotency.
- **M3** Tickets + MinIO signed-URL flow.
- **M4** Claude skill extension + Personal Access Tokens.
- **M5** Flutter foundation — auth, agenda, offline-first sync.
- **M6** Monthly calendar, ticket viewer, outbox + conflict UI.
- **M7** Costs + year-in-review stats + PDF viewer.
- **M8** Backups, deploy scripts, error reporting, polish, **v1.0.0 GA**.
- **M9** Watchlist — shared todo list with 2-level nesting, drag reorder,
  10-second sync polling.
- **M10** UI polish round — Material 3 refresh of every screen per Figma
  (agenda, detail, calendar, watchlist, stats), hero animations between
  agenda and detail, parallax cover + device-tilt, bottom nav redesign.
- **M11** Offline-first hardening + iOS TestFlight live —
  proactive image + ticket cache after each sync, past-event GC,
  WorkManager / BGTaskScheduler 30-min background refresh; **first iOS
  TestFlight build delivered to Běla 2026-05-22**.
- **M12** Proactive recommendations — Claude Code skill suite under
  `skills/`: `kulturni-prehled` aggregator (weekly via `/schedule`,
  the only skill that emails) + per-domain expert skills that produce
  ranked candidate JSON. **Phase 1 (2026-05-23)** ships
  `klasika-expert` (5 ensemble scrapers + festival WebFetch + Spotify
  + Discogs) and `elektronika-expert` (Spotify + venue WebFetch).
  Phase 2 will add `divadlo-expert` + `film-expert`.

## License

Proprietary — see [`LICENSE`](./LICENSE).

## Secrets

`.env` is gitignored and kept SOPS-encrypted in the private overlay
(`private/config/env.sops`) so it syncs across machines without plaintext in
git. With the overlay cloned into `./private` and the 1Password CLI signed in,
run `./scripts/secrets-decrypt.sh` to materialize `.env` (the age private key is
fetched from 1Password), or `./scripts/secrets-edit.sh` to change it.
Prereqs: `brew install sops age`.
