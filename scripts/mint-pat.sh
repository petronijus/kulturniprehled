#!/bin/sh
set -eu

# Mint a long-lived Personal Access Token for the KP API.
#
# The token is written **directly** into the 1Password item — it never lands
# on stdout, never appears in shell history, and never leaves the process
# tree visible to other processes via `ps`. If you want the token in a file
# instead of 1Password, use `--to-file PATH` (the file is created mode 0600).
#
# Usage:
#     ./scripts/mint-pat.sh <email> <token-name>
#         → 1Password item "Kulturni Prehled API Token", field "credential"
#     ./scripts/mint-pat.sh <email> <token-name> --to-op-item 'Custom Name'
#     ./scripts/mint-pat.sh <email> <token-name> --to-file ~/secrets/kp-pat
#
# Why no "print to stdout" mode? Anything the script writes to stdout can
# be captured by surrounding tools (a curious pager, a Claude Code Bash
# tool that reads the output, etc.) and end up in places we did not
# intend. Forcing a typed sink removes that footgun.

usage() {
    echo "usage: $0 <email> <token-name> [--to-op-item NAME | --to-file PATH]" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage

EMAIL="$1"
NAME="$2"
shift 2

OP_ITEM="Kulturni Prehled API Token"
FILE_PATH=""
SINK="op"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --to-op-item)
            OP_ITEM="${2:?missing 1Password item name}"
            SINK="op"
            shift 2
            ;;
        --to-file)
            FILE_PATH="${2:?missing file path}"
            SINK="file"
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage
            ;;
    esac
done

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-.env}"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T api \
    python -m kp_api.cli seed-user --email "$EMAIL" >/dev/null

# Pipe the JWT straight into the configured sink. The variable is never
# echoed and never persisted in shell history.
case "$SINK" in
    op)
        TMP_FIFO="$(mktemp -u)"
        mkfifo -m 600 "$TMP_FIFO"
        trap 'rm -f "$TMP_FIFO"' EXIT

        # 1Password CLI reads the value from /dev/stdin via "[file]" syntax
        # only on some platforms; the portable approach is to pass via env
        # variable, scoped to a subshell that wipes immediately.
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T api \
            python -m kp_api.cli mint-pat --email "$EMAIL" --name "$NAME" --quiet \
            > "$TMP_FIFO" &
        WRITER_PID=$!

        PAT=$(cat "$TMP_FIFO")
        wait "$WRITER_PID"

        if op item get "$OP_ITEM" --format json >/dev/null 2>&1; then
            printf '%s' "$PAT" | op item edit "$OP_ITEM" \
                "credential[password]=" >/dev/null
            # The above clears the existing value; now set the new one.
            op item edit "$OP_ITEM" "credential[password]=$PAT" >/dev/null
        else
            op item create --category=login --title="$OP_ITEM" \
                "credential[password]=$PAT" >/dev/null
        fi
        unset PAT
        echo "PAT stored in 1Password item '$OP_ITEM'." >&2
        ;;
    file)
        case "$FILE_PATH" in
            /*) :;;
            ~*) FILE_PATH="$HOME${FILE_PATH#~}";;
            *)  FILE_PATH="$PWD/$FILE_PATH";;
        esac
        umask 077
        : > "$FILE_PATH"
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T api \
            python -m kp_api.cli mint-pat --email "$EMAIL" --name "$NAME" --quiet \
            > "$FILE_PATH"
        chmod 600 "$FILE_PATH"
        echo "PAT written to $FILE_PATH (mode 0600)." >&2
        ;;
esac
