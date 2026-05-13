# Kulturní Přehled

Self-hosted cultural-event tracker for two users (Petr + Běla), with mobile
apps for Android and iOS and a Claude Code skill that ingests purchased
tickets and creates events automatically.

## Features

- Shared agenda of concerts, theatre, cinema and other cultural events.
- Mobile agenda view (chronological) and monthly calendar view.
- One-way sync to a shared Google Calendar.
- LLM-powered ticket ingestion: drop a ticket file into Claude on the
  desktop and the event, metadata, transport details and the ticket itself
  appear on both phones — offline.
- Offline-first mobile: tickets and event metadata cached locally so they
  work at the venue without signal. Inline image and PDF viewer.
- CZK cost tracking with year-in-review statistics.
- Offline edits queue in an outbox and reconcile with the server when the
  network returns; conflicts surface a "keep yours / use server" dialog.
- Optional self-hosted GlitchTip / Sentry error reporting.
- Infrastructure prepared for a future proactive AI recommendations agent.

## Stack

- **Backend** — Python 3.12, FastAPI, SQLAlchemy 2.0 async, PostgreSQL 16,
  Alembic, MinIO (S3-compatible).
- **Mobile** — Flutter (Android primary, iOS feature parity), drift (SQLite),
  Riverpod, go_router, Material 3 dark theme, pdfrx.
- **LLM** — Anthropic Claude API behind a `LLMProvider` abstraction.
- **Public access** — Cloudflare Tunnel, two subdomains
  (`api.kp.*` for the API, `tickets.kp.*` for MinIO signed URLs).
- **Auth** — Google OAuth2 (PKCE on mobile) + JWT (15 min) + refresh-token
  rotation with reuse detection. Personal access tokens for headless
  clients (the Claude skill).

See [`CLAUDE.md`](./CLAUDE.md) for the development guide.

## Repository layout

```
apps/api/            FastAPI service
apps/mobile/         Flutter app
packages/            OpenAPI snapshot
skills/ticket-parser Claude Code skill source
infra/
  docker-compose.yml    dev stack (Postgres + MinIO + API)
  compose.prod.yml      prod overlay (cloudflared, hardened ports)
  compose.glitchtip.yml optional error-reporting overlay
  cloudflared/          tunnel config example
  deploy/               setup-vm.sh + upgrade.sh + README
  backup/               pg_dump, mc_mirror, restore-test, cron.example
docs/                Architecture, sync, deployment notes
```

## Quick start (development)

Prerequisites:
- Docker and Docker Compose v2
- Python 3.12+ (only needed for running backend tests outside Docker)
- Flutter 3.x (only needed for the mobile app)

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
pip install -e ".[dev]"
pytest

# Mobile
cd apps/mobile
flutter test
```

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
- **M9+** AI recommendations agent (deferred — schema is in place).

## License

Proprietary — see [`LICENSE`](./LICENSE).
