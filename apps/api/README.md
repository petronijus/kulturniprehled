# `kp-api` — Kulturní Přehled backend

FastAPI service. See the top-level [AGENTS.md](../../AGENTS.md) for project
rules and conventions, and [docs/development.md](../../docs/development.md)
for the toolchain.

## Local development

```bash
uv sync                                     # Python 3.12 (.python-version) + the dev group
uv run uvicorn kp_api.main:app --reload
```

Tests and checks, from the repository root:

```bash
just test-api    # pytest against Postgres and MinIO in testcontainers (Docker must run)
just lint-py     # ruff + mypy --strict
```

The `Dockerfile` here and `infra/docker-compose.yml` at the repository root
run the service together with Postgres and MinIO (`just dev-up`).
