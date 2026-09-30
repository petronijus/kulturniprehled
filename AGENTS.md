# Kulturní Přehled — instructions for coding agents

Self-hosted cultural-event tracker shared by two people (Petr and Běla): a
FastAPI backend, Flutter apps for Android and iOS, a season-planner SPA, and
Claude Code skills that ingest tickets, scrape Prague programmes and plan a
concert season. This file is for every coding agent (Claude Code, Cursor,
Codex, …); humans start at `README.md`.

| Layer | Choice |
|---|---|
| Backend | Python 3.12, FastAPI, SQLAlchemy 2.1 async, PostgreSQL 16, Alembic, MinIO |
| Mobile | Flutter 3.47.5, drift (SQLite), Riverpod, go_router, Material 3 |
| Planner | React + Vite SPA served by the API at `/app` (home network only) |
| Auth | Google OAuth2 (PKCE) → JWT + refresh-token rotation; scoped PATs for the skills |
| Background | WorkManager / BGTaskScheduler 30-min sync + local notifications (no APNs/FCM, `docs/architecture.md`) |
| LLM | Anthropic Claude API behind an `LLMProvider` abstraction |
| Hosting | Proxmox VM, Docker Compose, Cloudflare Tunnel; image on GHCR |

Read `docs/sync.md` before touching sync, the outbox or any synced entity,
`docs/architecture.md` before touching notifications or background work, and
`docs/release.md` before a release.

## Hard rules

- **Sync invariants** (`docs/sync.md`):
  1. `change_log.seq` is a monotonic `bigserial` — never decreased, never
     set manually.
  2. The client never writes `version`; the server increments it on every
     upsert.
  3. `op_id` is the idempotency key for `POST /v1/sync/apply`; retries are
     safe.
  4. Soft delete only: the API sets `deleted_at` and never hard-deletes; a
     nightly job purges tombstones older than 90 days.
- **Silent failure is a bug.** Every past incident was one (an alarm with no
  receiver, a token race that logged a phone out, a scraper that dated every
  concert wrong). Never swallow an error on the notification, sync, auth or
  scrape path; log it and surface it.
- **Android first, iOS parity.** Android is the primary target; iOS keeps
  full feature parity. No Android-only features, no Cupertino-only widgets,
  every package must work on both.
- **Brand assets are Petr's.** Never create, regenerate or "improve" a file
  in `assets-source/brand/`; downstream icons are only resized from those
  masters (`assets-source/brand/README.md`). A hook enforces it.
- **This repository is public.** No real IP addresses, private hostnames,
  personal e-mails, street addresses, Apple team IDs or device IDs — use the
  placeholders already in the docs (`192.0.2.x`, `*.example.com`,
  `YOURTEAMID`) and keep real values in the private overlay (`private/`, a
  separate private repo). The pre-commit hook scans for them.
- **Secrets** live in 1Password (`op-cache`) and SOPS-encrypted in the
  private overlay (`scripts/secrets-edit.sh`); never commit, print or log
  them.
- **Performance budgets:** API p95 ≤ 200 ms, mobile cold start ≤ 2 s. N+1
  queries are forbidden (eager-load with `selectinload` / `joinedload`);
  request handlers are async and never call sync DB methods.
- **Season-plan contracts:** `skills/kulturni-sezona/bin/kp_validate.py` is
  the constraint canon and `apps/api/web/src/domain/violations.ts` its
  mirror; the `dedup_key` recipe in `skills/kulturni-sezona/SKILL.md` never
  changes casually.
- Every bug fix adds a regression test.
- All code, comments, docs, logs, commit messages and UI strings are in
  English. Only user content (event titles, programme notes) may be Czech.

## Commands

`just` is the only entry point; `just` alone lists every recipe.

| Command | What it does |
|---|---|
| `just setup` | check the toolchain, install git hooks, `flutter pub get`, `uv sync`, `npm ci` |
| `just check` | fast lane (~1 min): formatting, all analyzers, Dart, API (testcontainers), web and script tests |
| `just ci` | full gate: fast lane + debug APK, SPA bundle, API image, and the iOS build on macOS |
| `just fmt` | format everything (`tools/dev/format.sh`) |
| `just test-api` / `test-dart` / `test-web` / `test-scripts` | one test layer |
| `just lint-py` / `lint-dart` / `lint-web` / `lint-shell` | one analyzer |
| `just build-aab` | signed bundle for Play internal testing (upload key from 1Password) |
| `just dev-up` / `dev-down` | the dev stack (Postgres, MinIO, API) |
| `just secrets-decrypt` | materialise `.env` from the private overlay |
| `just run` | the app on a connected device or simulator |

There is no hosted CI. `just ci` is the CI, run on the Linux desktop
(everything except iOS) or the MacBook (all lanes); the pre-push hook runs
`just check`.

## Definition of done

1. Code written and formatted; `just ci` green.
2. Tests written; every bug fix has a regression test.
3. Conventional Commit.
4. Merged into `main` locally and pushed (branch deleted on both ends), or
   committed straight to `main` for a trivial fix.
5. Deployed when the API or the SPA changed (`docs/release.md`, step 6).
6. Verified by hand: dev stack up, UI clicked through or endpoint curled.

## Git workflow

- `main` is always deployable. Work in `feat/*` or `fix/*`, then **merge
  into `main` locally** and push — solo project, no pull requests. The
  commit message carries what a PR description would: summary, why, test
  plan, and for UI changes what was verified by looking at it.
- After every fix: commit and push. After every milestone: tag
  (`vX.Y.Z`), push the tag, ship the bundle to Play internal testing and
  the build to TestFlight (`docs/release.md`).
- Never `--no-verify`, never force-push `main`.

## Layout

```
apps/api/          FastAPI service (src/kp_api, alembic, tests)
apps/api/web/      season-planner SPA (React + Vite), served at /app
apps/mobile/       Flutter app (Android + iOS)
skills/            Claude Code skills: ticket ingest, domain experts, season planner
infra/             compose files, deploy, backup, claudebox timers, iOS release scripts
scripts/           image build + push, secrets, PAT minting, iOS private-value injection
assets-source/     brand masters (Petr's; read-only)
packages/          OpenAPI snapshot
tools/dev/         formatter, doctor, commit-msg check, PII scan
docs/              architecture, sync, API, release, deployment, development
private/           private overlay (gitignored; its own repo)
```

## Conventions

- Conventional Commits (`type(scope): summary`, ≤ 72 characters), enforced
  by the commit-msg hook. Scopes: `mobile`, `android`, `ios`, `api`, `web`,
  `season`, `skills`, `klasika`, `claudebox`, `infra`, `deploy`, `dev`, …
- **Python** (`apps/api`): ruff (lint + format, config in `pyproject.toml`)
  and mypy `--strict`. Scripts outside the API: ruff via the root
  `ruff.toml`, stdlib only, Python 3.9-compatible.
- **Dart**: `dart format`, `flutter_lints` with strict casts/inference/raw
  types, no `dynamic`, no `late` unless unavoidable.
- **Web**: Biome + `tsc --noEmit`, vitest.
- **Shell**: shellcheck-clean; a disabled check carries its reason.
- **No comments unless the WHY is non-obvious.** Names carry the what;
  ticket and incident references belong in commit messages.
- Toolchain pins: Flutter 3.47.5 (`.flutter-version`, Swift Package Manager
  disabled), JDK 25, AGP 9.2.1, Gradle 9.4.1, Kotlin 2.4.20, Python 3.12
  (`apps/api/.python-version`, as in the image), Node 22
  (`apps/api/web/.nvmrc`), Docker. `just doctor` checks them.
- Formatting is automatic (pre-commit hook): `dart format`, ruff,
  Biome, ktlint (`.editorconfig`), swift-format
  (`apps/mobile/ios/.swift-format`, macOS only).
- Deploy: the API image is built locally and pushed to GHCR; the VM only
  pulls (`scripts/build-push.sh`, `infra/deploy/upgrade.sh`).
- Time zone for everything human-facing: Europe/Prague.

Details, per-OS setup and troubleshooting: `docs/development.md`.
