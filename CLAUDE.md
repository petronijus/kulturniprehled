# Kulturní Přehled — Development Guide

Self-hosted cultural-event tracker shared between two users (Petr + Běla).
Backend in FastAPI, mobile apps in Flutter, LLM-powered ticket ingestion via an
extended Claude Code skill.

## Stack

| Layer        | Choice                                                                |
| ------------ | --------------------------------------------------------------------- |
| Backend      | Python 3.12, FastAPI, SQLAlchemy 2.0 async, PostgreSQL 16, Alembic    |
| Mobile       | Flutter (Android primary, iOS parity), drift (SQLite), Riverpod       |
| Object store | MinIO (S3-compatible), self-hosted                                    |
| LLM          | Anthropic Claude API behind a `LLMProvider` abstraction               |
| Hosting      | Proxmox VM, Docker Compose, Cloudflare Tunnel                         |
| Auth         | Google OAuth2 (PKCE) → backend issues JWT + refresh-token rotation    |
| Push         | APNs (iOS) + FCM (Android) behind `NotificationProvider` abstraction  |
| CI/CD        | GitHub Actions, GHCR registry                                         |

## Language policy

All code, comments, docs, commit messages, and PR descriptions are in **English**.
Only the chat conversation with the user can remain Czech.

## Mobile platform policy

Android is the primary development and testing target — fastest iteration loop.
iOS keeps **full feature parity**, no Android-only features allowed. Every
package choice must work identically on both. Material 3 design system avoids
Cupertino-only widgets while still feeling native enough. CI builds `.apk` and
`.ipa` from day 1.

## Repository layout

```
apps/api/          FastAPI service
apps/mobile/       Flutter app (Android + iOS)
packages/          Shared specs / generated clients
skills/            Claude Code skill source (ticket parser)
infra/             Docker Compose, Cloudflare Tunnel, backup scripts
docs/              Architecture, API, sync, deployment docs
.github/workflows/ CI pipelines
```

## Conventions

- **Commits**: [Conventional Commits](https://www.conventionalcommits.org/) —
  `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`, `perf:`, `ci:`.
- **Branches**: `main` is always deployable. Work in `feat/*` or `fix/*` branches,
  open PRs into `main`. Branch protection: required CI green + linear history.
- **PR template**: change summary, why, test plan, screenshots for UI changes.

## Code style

- **Python**: ruff + black + mypy `--strict`. Async-only request handlers, never
  call sync DB methods from request paths.
- **Dart**: `dart format`, `flutter_lints` strict, no `dynamic`, no `late`
  unless absolutely required.
- **No comments unless the WHY is non-obvious.** Identifier names carry the
  WHAT; references to tickets/PRs/incidents belong in commit messages.

## Testing strategy

- **Backend** (`apps/api`): pytest + testcontainers (real Postgres + MinIO in
  tests, no DB mocks). Coverage goal 80% overall, 95% on sync + auth.
- **Mobile** (`apps/mobile`): `flutter test` for widgets and business logic,
  `integration_test` for end-to-end flows (login, create event, sync, ticket
  download). Primary target Android emulator + a physical Android device;
  iOS smoke test on Simulator + occasional physical device.
- **End-to-end**: pytest scenario invoking the API the same way the Claude
  skill does, asserting Calendar entry + MinIO blob.

## Definition of done

1. Code written, formatted, lint passes.
2. Tests written and green. Every bug fix adds a regression test.
3. Commit in Conventional Commit format.
4. Push to a feature branch, open PR.
5. CI green: lint + tests + Android `.apk` build + iOS `.ipa` build.
6. Manual verification (dev compose up, click through UI or curl endpoint).

## Commit cadence (explicit project policy)

- **After every fix**: commit + push.
- **After every milestone (M0…M8)**: tag (`v0.1.0`, … `v1.0.0`), push the tag,
  write GitHub release notes.
- **Never** `--no-verify`. **Never** force-push to `main`.

## Secrets

- 1Password CLI: `op-cache "kulturni-prehled api-token" credential`.
- No secrets in the repo. `.env.example` is the template; `.env` is gitignored.
- Google OAuth client is reused from a sibling project (key in 1Password) —
  only the redirect URI is added per app.

## Sync invariants (critical, do not violate)

1. Server `change_log.seq` is a monotonic `bigserial` — never decreased, never
   set manually.
2. Client never writes `version` — server increments on every upsert.
3. `op_id` is the idempotency key for `POST /v1/sync/apply`. Retries are safe.
4. Soft delete only: API never hard-deletes; only `deleted_at` is set. A
   nightly batch job purges tombstones older than 90 days.

## Performance budgets

- API endpoint p95 > 200 ms → optimize.
- Mobile cold start > 2 s → optimize.
- N+1 queries are forbidden; always eager-load via `selectinload` /
  `joinedload`.

## Deployment

- Proxmox VM (Ubuntu Server LTS) running `infra/compose.prod.yml`.
- Cloudflare Tunnel exposes two subdomains: `api.kp.*` for the API, and
  `tickets.kp.*` for MinIO signed-URL traffic.
- Nightly `pg_dump` → MinIO `backups/` bucket → `mc mirror` to Backblaze B2
  for offsite. Quarterly test restore drill (script in `infra/backup/`).

## See also

- `README.md` — quick-start, contributors guide.
- `docs/architecture.md` — system architecture, sequence diagrams.
- `docs/sync.md` — sync algorithm, conflict resolution.
- `docs/api.md` — REST API reference (also OpenAPI at `/openapi.json`).
- `docs/deployment.md` — Proxmox VM setup, Cloudflare Tunnel config.
