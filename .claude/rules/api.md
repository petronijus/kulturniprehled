---
paths:
  - "apps/api/src/**"
  - "apps/api/alembic/**"
  - "apps/api/tests/**"
---
# API (apps/api)

- Sync invariants (docs/sync.md): `change_log.seq` is DB-assigned and
  monotonic; one `change_log` row per synced mutation, same transaction;
  the server owns `version`; `op_id` makes `/v1/sync/apply` idempotent;
  soft delete only.
- Async-only handlers; no sync DB calls on request paths. No N+1: eager
  load with `selectinload` / `joinedload`. p95 budget 200 ms.
- Every schema change is an Alembic revision with a working downgrade.
  Prod runs a pinned image tag; an image older than the DB head crash-loops.
- Scopes are default-deny. Season tables are web-only and not synced to
  mobile.
- Tests use real Postgres and MinIO (testcontainers); no DB mocks. Sync and
  auth changes need tests.
- ruff (config in pyproject.toml), mypy `--strict`. Python 3.12 as in the
  image (`.python-version`).
