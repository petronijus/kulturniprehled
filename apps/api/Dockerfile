# Stage 1 — season-planner SPA bundle
FROM node:22-slim AS webbuild

# Google Web OAuth client id baked into the bundle (Vite build-time env).
# Without it the SPA builds fine but the sign-in button errors at runtime.
ARG VITE_KP_GOOGLE_CLIENT_ID=""
ENV VITE_KP_GOOGLE_CLIENT_ID=${VITE_KP_GOOGLE_CLIENT_ID}

WORKDIR /web

COPY web/package.json web/package-lock.json ./
RUN npm ci

COPY web ./
RUN npm run build

# Stage 2 — API image (serves the SPA bundle at /app)
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libpq-dev curl \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml README.md alembic.ini ./
COPY src ./src
COPY alembic ./alembic

RUN pip install -e .

COPY --from=webbuild /web/dist ./web/dist

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD curl -fsS http://localhost:8000/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["uvicorn", "kp_api.main:app", "--host", "0.0.0.0", "--port", "8000"]

# Link this GHCR package to its source repo (auto-connects on push)
LABEL org.opencontainers.image.source=https://github.com/petronijus/kulturniprehled
