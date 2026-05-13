# Kulturní Přehled

Self-hosted cultural-event tracker for two users (Petr + Běla), with mobile
apps for Android and iOS and a Claude Code skill that ingests purchased
tickets and creates events automatically.

## Features

- Shared agenda of concerts, theatre, cinema and other cultural events.
- Mobile agenda view (chronological) and monthly calendar view.
- One-way sync to a shared Google Calendar.
- LLM-powered ticket ingestion: drop a ticket file into Claude on the desktop
  and the event, metadata, image, transport details and the ticket itself
  appear on both phones — offline.
- Offline-first mobile: tickets and event metadata cached locally so they
  work at the venue without signal.
- Cost tracking (multi-currency) and year-in-review statistics from day one.
- Infrastructure prepared for a future proactive AI recommendations agent.

## Stack

Python 3.12 + FastAPI + PostgreSQL + MinIO on the backend, Flutter on mobile,
Anthropic Claude API for parsing, Google OAuth2 + Cloudflare Tunnel for
access. See [`CLAUDE.md`](./CLAUDE.md) for the development guide.

## Repository layout

```
apps/api/          FastAPI service
apps/mobile/       Flutter app
packages/          Shared specs / generated clients
skills/            Claude Code skill source
infra/             Docker Compose, Cloudflare Tunnel, backups
docs/              Architecture and operational documentation
```

## Quick start (development)

Prerequisites:
- Docker and Docker Compose v2
- Python 3.12+ (for running tests locally outside Docker)
- Flutter 3.x (only needed when working on the mobile app)
- A `.env` file copied from `.env.example`

```bash
cp .env.example .env
# edit .env, at minimum set ANTHROPIC_API_KEY and GOOGLE_OAUTH_* values

# Start backend, Postgres and MinIO
docker compose -f infra/docker-compose.yml up -d

# Tail logs
docker compose -f infra/docker-compose.yml logs -f api

# Health check
curl http://localhost:8000/healthz
```

## Testing

```bash
# Backend
cd apps/api
pip install -e ".[dev]"
pytest

# Mobile (when set up)
cd apps/mobile
flutter test
```

## Roadmap (milestones)

- **M0**  Repo bootstrap (this commit)
- **M1**  Backend foundation, Google OAuth, base CRUD
- **M2**  Sync API + `change_log`
- **M3**  Tickets + MinIO + signed URLs
- **M4**  Claude skill extension talks to the API
- **M5**  Flutter foundation, auth, agenda view
- **M6**  Monthly calendar, ticket viewer, sync robustness
- **M7**  Costs + statistics infrastructure
- **M8**  Push notifications, polish, v1.0.0 GA
- **M9+** AI recommendations agent (deferred)

## License

Proprietary — see [`LICENSE`](./LICENSE).
