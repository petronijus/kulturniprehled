#!/bin/sh
set -eu

# Safe upgrade flow: fetch the latest main, pull the API image, run
# migrations against the running Postgres, then roll the API service.
#
# Stops short of a force restart on Postgres or MinIO — those upgrade
# manually after a manual review of release notes. This script is meant
# for the routine "new feature is on main, deploy it" case.
#
# By default only docker-compose.yml is applied, which publishes host
# ports (15432/19000/18000/19001) so an external Cloudflare Tunnel running
# off-stack can reach the services. To run with the bundled in-stack
# cloudflared instead, point COMPOSE_PROD at infra/compose.prod.yml and
# set CLOUDFLARE_TUNNEL_TOKEN in .env; the overlay then strips host
# ports and joins the tunnel container to the internal Docker network.
#
# Run as the 'deploy' user (the one that owns /opt/kp).

INSTALL_DIR="${INSTALL_DIR:-/opt/kp}"
ENV_FILE="${ENV_FILE:-$INSTALL_DIR/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$INSTALL_DIR/infra/docker-compose.yml}"
COMPOSE_PROD="${COMPOSE_PROD:-}"

PROD_OVERLAY=""
if [ -n "$COMPOSE_PROD" ]; then
    PROD_OVERLAY="-f $COMPOSE_PROD"
fi

cd "$INSTALL_DIR"

echo "[upgrade] git pull"
git pull --ff-only

echo "[upgrade] pulling new API image"
# shellcheck disable=SC2086
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" $PROD_OVERLAY \
    pull api

echo "[upgrade] running migrations"
# Migrations live in the container entrypoint, but we run them once up-front
# so a half-broken migration doesn't take the running API down with it.
# shellcheck disable=SC2086
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" $PROD_OVERLAY \
    run --rm -e RUN_MIGRATIONS=1 --entrypoint /bin/sh api \
    -c "alembic upgrade head"

echo "[upgrade] restarting api with the pulled image (no build on the VM)"
# The API image is built + pushed LOCALLY (scripts/build-push.sh) and pulled
# above — the VM never builds from source. Set KP_API_TAG to deploy a specific
# tag (defaults to :latest).
# shellcheck disable=SC2086
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" $PROD_OVERLAY \
    up -d --no-deps api

echo "[upgrade] waiting for /healthz..."
for i in $(seq 1 30); do
    # shellcheck disable=SC2086
    if docker compose --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" $PROD_OVERLAY \
            exec -T api curl -fsS http://localhost:8000/healthz >/dev/null 2>&1; then
        echo "[upgrade] healthy after ${i}s."
        exit 0
    fi
    sleep 1
done

echo "[upgrade] WARNING: api did not pass /healthz within 30s"
# shellcheck disable=SC2086
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" $PROD_OVERLAY logs --tail=50 api
exit 1
