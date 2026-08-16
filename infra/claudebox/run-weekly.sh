#!/usr/bin/env bash
# Launch ONE headless weekly novelty-watcher session on the claudebox.
# Invoked by kulturni-prehled-weekly.timer (Sat 11:00 Europe/Prague) or by
# hand for a test run. Runs `claude -p` on the operator subscription (no
# Anthropic API key). Models ai-config's repo-maintenance runner.
#
# Secrets: ~/.config/kulturni-prehled/kp-token (0600) holds the scoped PAT
# (digest:read feedback:sign digest:send events:read season:read season:write) —
# provisioned per infra/claudebox/README.md. The shared calendar is NOT a
# secret of this box any more: the API holds the iCal address
# (CALENDAR_ICS_URL in its .env) and serves GET /v1/season/calendar.
set -euo pipefail

# Manual ssh runs come in with a bare non-login PATH — make claude et al.
# resolvable regardless of how we were invoked.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CFG_DIR="${CFG_DIR:-$HOME/.config/kulturni-prehled}"
LOGDIR="$CFG_DIR/logs"; mkdir -p "$LOGDIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/weekly-$STAMP.log"

# Fresh checkout — the playbook and skills are read from the repo.
git -C "$REPO" pull --ff-only -q || echo "[warn] git pull failed, running on the existing checkout"

TOKEN_FILE="$CFG_DIR/kp-token"
[ -r "$TOKEN_FILE" ] || { echo "FATAL: $TOKEN_FILE missing (see infra/claudebox/README.md)"; exit 1; }
KP_DIGEST_TOKEN="$(cat "$TOKEN_FILE")"
export KP_DIGEST_TOKEN
export KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.bastla.com}"

ALLOWED="$(grep -vE '^\s*(#|$)' "$HERE/allowed-tools-weekly.txt" | paste -sd, -)"

PROMPT="$(cat "$REPO/skills/kulturni-prehled/claudebox-routine.md")
Repo checkout: $REPO. Today (UTC): $STAMP."

echo "[$(date -u +%FT%TZ)] launching kulturni-prehled weekly; log=$LOG"
claude -p "$PROMPT" \
  --allowedTools "$ALLOWED" \
  --add-dir "$REPO" \
  --output-format text \
  2>&1 | tee "$LOG"

echo "[$(date -u +%FT%TZ)] weekly run finished; report in $LOG"

NOTIFY="$CFG_DIR/notify"
if [ -x "$NOTIFY" ]; then
  "$NOTIFY" < "$LOG" || echo "[warn] notify hook failed"
fi
