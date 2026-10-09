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
    # shellcheck source=/dev/null # the env file lives on the VM, not in the repo
    . "$ENV_FILE"
    set +a
fi

: "${B2_ACCOUNT_ID:?B2_ACCOUNT_ID not set in .env}"
: "${B2_APPLICATION_KEY:?B2_APPLICATION_KEY not set in .env}"
: "${B2_BUCKET_NAME:?B2_BUCKET_NAME not set in .env}"

BACKUPS="${MINIO_BACKUP_BUCKET:-backups}"
TICKETS="${MINIO_BUCKET_TICKETS:-tickets}"

echo "[mc_mirror] starting at $(date -u +%Y%m%dT%H%M%SZ)"
# minio-init is the stack's `mc` shell. The MinIO credentials are in its
# compose environment, the B2 ones are passed through from the sourced .env
# (`-e NAME` without a value); all expand inside the container (hence the
# single quotes). Region, buckets and the B2 bucket arrive as $1..$4.
# shellcheck disable=SC2016 # the script expands its variables in the container
docker compose --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" -f "$COMPOSE_PROD" \
    run --rm -T -e B2_ACCOUNT_ID -e B2_APPLICATION_KEY \
    --entrypoint /bin/sh minio-init -c '
        mc alias set kp http://minio:9000 "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null &&
        mc alias set b2 "https://s3.$1.backblazeb2.com" "$B2_ACCOUNT_ID" "$B2_APPLICATION_KEY" >/dev/null &&
        mc mirror --overwrite --remove "kp/$2" "b2/$4/$2" &&
        mc mirror --overwrite "kp/$3" "b2/$4/$3"
    ' sh "${B2_REGION:-eu-central-003}" "$BACKUPS" "$TICKETS" "$B2_BUCKET_NAME"

echo "[mc_mirror] done."
