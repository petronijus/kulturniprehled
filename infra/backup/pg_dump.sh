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
    # shellcheck source=/dev/null # the env file lives on the VM, not in the repo
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
# minio-init is the stack's `mc` shell; its credentials are in its compose
# environment and expand inside the container (hence the single quotes),
# bucket and key arrive as $1 and $2. The dump streams in on stdin: the
# image runs as nonroot 65532, which cannot read this 0600 temp file through
# a bind mount.
# shellcheck disable=SC2016 # the script expands its variables in the container
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    run --rm -T --entrypoint /bin/sh minio-init -c '
        mc alias set kp http://minio:9000 "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null &&
        mc mb --ignore-existing "kp/$1" >/dev/null &&
        mc pipe "kp/$1/$2"
    ' sh "$BUCKET" "$KEY" < "$TMP"

echo "[pg_dump] done."
