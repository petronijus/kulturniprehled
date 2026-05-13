#!/bin/sh
set -eu

# Nightly Postgres dump → MinIO `backups/` bucket.
#
# Intended to be invoked by cron on the host running the docker-compose
# stack. The script execs into the Postgres container via the running
# compose service so it never needs network access of its own. The dump is
# written to a temp file, gzipped, then uploaded to MinIO with the date in
# the object name so reverse-chronological listing just works.
#
# Required environment (sourced from .env):
#   POSTGRES_USER POSTGRES_DB MINIO_ENDPOINT MINIO_ACCESS_KEY
#   MINIO_SECRET_KEY  MINIO_BACKUP_BUCKET (defaults to "backups")
#
# Recommended cron (see cron.example):
#   17 3 * * *  /opt/kp/infra/backup/pg_dump.sh >> /var/log/kp-backup.log 2>&1

ENV_FILE="${ENV_FILE:-/opt/kp/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/kp/infra/docker-compose.yml}"
COMPOSE_PROD="${COMPOSE_PROD:-/opt/kp/infra/compose.prod.yml}"
BUCKET="${MINIO_BACKUP_BUCKET:-backups}"
PREFIX="postgres"
NOW="$(date -u +%Y%m%dT%H%M%SZ)"

if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
fi

TMP="$(mktemp -t kp-pg.XXXXXX.sql.gz)"
trap 'rm -f "$TMP"' EXIT

echo "[pg_dump] dumping $POSTGRES_DB at $NOW"
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    exec -T postgres \
    pg_dump -U "$POSTGRES_USER" --no-owner --clean --if-exists "$POSTGRES_DB" \
    | gzip --best > "$TMP"

SIZE_BYTES="$(stat -c '%s' "$TMP")"
KEY="${PREFIX}/${NOW}.sql.gz"

echo "[pg_dump] uploading ${SIZE_BYTES} B → s3://${BUCKET}/${KEY}"
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    run --rm -T \
    -v "$TMP:/dump.sql.gz:ro" \
    minio-init \
    /bin/sh -c "
        mc alias set kp http://minio:9000 \
            \${MINIO_ACCESS_KEY} \${MINIO_SECRET_KEY} >/dev/null &&
        mc mb --ignore-existing kp/${BUCKET} >/dev/null &&
        mc cp /dump.sql.gz kp/${KEY}
    "

echo "[pg_dump] done."
