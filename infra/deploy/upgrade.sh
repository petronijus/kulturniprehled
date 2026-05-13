#!/bin/sh
set -eu

# Safe upgrade flow: fetch the latest main, pull the API image, run
# migrations against the running Postgres, then roll the API service.
#
# Stops short of a force restart on Postgres or MinIO — those upgrade
# manually after a manual review of release notes. This script is meant
# for the routine "new feature is on main, deploy it" case.
#
# Run as the 'deploy' user (the one that owns /opt/kp).

INSTALL_DIR="${INSTALL_DIR:-/opt/kp}"
ENV_FILE="${ENV_FILE:-$INSTALL_DIR/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$INSTALL_DIR/infra/docker-compose.yml}"
COMPOSE_PROD="${COMPOSE_PROD:-$INSTALL_DIR/infra/compose.prod.yml}"

cd "$INSTALL_DIR"

echo "[upgrade] git pull"
git pull --ff-only

echo "[upgrade] pulling new API image"
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    pull api

echo "[upgrade] running migrations"
# Migrations live in the container entrypoint, but we run them once up-front
# so a half-broken migration doesn't take the running API down with it.
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    run --rm -e RUN_MIGRATIONS=1 --entrypoint /bin/sh api \
    -c "alembic upgrade head"

echo "[upgrade] restarting api (zero-downtime within compose limits)"
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    up -d --no-deps --build api

echo "[upgrade] waiting for /healthz..."
for i in $(seq 1 30); do
    if docker compose --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
            exec -T api curl -fsS http://localhost:8000/healthz >/dev/null 2>&1; then
        echo "[upgrade] healthy after ${i}s."
        exit 0
    fi
    sleep 1
done

echo "[upgrade] WARNING: api did not pass /healthz within 30s"
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" logs --tail=50 api
exit 1
