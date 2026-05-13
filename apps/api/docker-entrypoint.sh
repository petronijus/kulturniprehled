#!/bin/sh
set -e

# Run database migrations before starting the API.
# Skipped when RUN_MIGRATIONS=0 (e.g. for a one-shot shell into the image).
if [ "${RUN_MIGRATIONS:-1}" = "1" ]; then
    echo "[entrypoint] running alembic upgrade head..."
    alembic upgrade head
fi

exec "$@"
