# `kp-api` — Kulturní Přehled backend

FastAPI service. See the [top-level CLAUDE.md](../../CLAUDE.md) for project
context and conventions.

## Local development

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
uvicorn kp_api.main:app --reload
```

Tests:

```bash
pytest
```

The `Dockerfile` and `infra/docker-compose.yml` at the repository root run the
service together with Postgres and MinIO.
