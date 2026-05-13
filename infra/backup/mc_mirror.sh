#!/bin/sh
set -eu

# Mirror MinIO `backups/` and `tickets/` to Backblaze B2 for off-site
# durability. Runs once per day right after pg_dump.sh.
#
# Required environment (sourced from .env):
#   MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_BACKUP_BUCKET (default backups)
#   MINIO_BUCKET_TICKETS B2_ACCOUNT_ID B2_APPLICATION_KEY B2_BUCKET_NAME
#
# Both buckets are mirrored — `tickets` covers user uploads, `backups`
# covers nightly DB dumps. Both directions are one-way (B2 receives only).

ENV_FILE="${ENV_FILE:-/opt/kp/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/kp/infra/docker-compose.yml}"
COMPOSE_PROD="${COMPOSE_PROD:-/opt/kp/infra/compose.prod.yml}"

if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
fi

: "${B2_ACCOUNT_ID:?B2_ACCOUNT_ID not set in .env}"
: "${B2_APPLICATION_KEY:?B2_APPLICATION_KEY not set in .env}"
: "${B2_BUCKET_NAME:?B2_BUCKET_NAME not set in .env}"

BACKUPS="${MINIO_BACKUP_BUCKET:-backups}"
TICKETS="${MINIO_BUCKET_TICKETS:-tickets}"

echo "[mc_mirror] starting at $(date -u +%Y%m%dT%H%M%SZ)"
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    run --rm -T minio-init \
    /bin/sh -c "
        mc alias set kp http://minio:9000 \
            \${MINIO_ACCESS_KEY} \${MINIO_SECRET_KEY} >/dev/null &&
        mc alias set b2 https://s3.${B2_REGION:-eu-central-003}.backblazeb2.com \
            \${B2_ACCOUNT_ID} \${B2_APPLICATION_KEY} >/dev/null &&
        mc mirror --overwrite --remove kp/${BACKUPS} b2/${B2_BUCKET_NAME}/${BACKUPS} &&
        mc mirror --overwrite kp/${TICKETS} b2/${B2_BUCKET_NAME}/${TICKETS}
    "

echo "[mc_mirror] done."
