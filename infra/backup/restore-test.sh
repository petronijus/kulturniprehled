#!/bin/sh
set -eu

# Quarterly disaster drill: pull the most recent dump, restore into a
# scratch Postgres container, and run a sanity query. Refuses to touch
# the live `postgres` service — the scratch container is named
# `kp-restore-test` and is torn down at the end (unless --keep is passed).
#
# Required environment (sourced from .env):
#   POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD
#   MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_BACKUP_BUCKET

ENV_FILE="${ENV_FILE:-/opt/kp/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/kp/infra/docker-compose.yml}"
COMPOSE_PROD="${COMPOSE_PROD:-/opt/kp/infra/compose.prod.yml}"
KEEP="${KEEP:-0}"
SCRATCH="kp-restore-test"

if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
fi

BUCKET="${MINIO_BACKUP_BUCKET:-backups}"
TMP="$(mktemp -d -t kp-restore.XXXXXX)"

trap '
    rm -rf "$TMP"
    if [ "$KEEP" != "1" ]; then
        docker rm -f "$SCRATCH" >/dev/null 2>&1 || true
    fi
' EXIT

echo "[restore-test] fetching latest dump from MinIO..."
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    run --rm -T \
    -v "$TMP:/out" \
    minio-init \
    /bin/sh -c "
        mc alias set kp http://minio:9000 \
            \${MINIO_ACCESS_KEY} \${MINIO_SECRET_KEY} >/dev/null &&
        LATEST=\$(mc ls kp/${BUCKET}/postgres/ | awk '{print \$NF}' | sort | tail -n 1) &&
        echo \"[restore-test] latest: \$LATEST\" &&
        mc cp kp/${BUCKET}/postgres/\$LATEST /out/dump.sql.gz
    "

echo "[restore-test] starting scratch postgres..."
docker run -d --rm --name "$SCRATCH" \
    -e POSTGRES_USER="$POSTGRES_USER" \
    -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -e POSTGRES_DB="$POSTGRES_DB" \
    postgres:16-alpine >/dev/null

# Wait for readiness.
for i in $(seq 1 30); do
    if docker exec "$SCRATCH" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

echo "[restore-test] restoring dump..."
gunzip -c "$TMP/dump.sql.gz" \
    | docker exec -i "$SCRATCH" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 >/dev/null

echo "[restore-test] smoke query..."
COUNT_EVENTS=$(docker exec "$SCRATCH" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
        "SELECT COUNT(*) FROM events WHERE deleted_at IS NULL")
echo "[restore-test] restored event count: $COUNT_EVENTS"

if [ "$KEEP" = "1" ]; then
    echo "[restore-test] keeping scratch container (KEEP=1)."
else
    echo "[restore-test] tearing down scratch."
fi
