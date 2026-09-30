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
RUN="weekly"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/$RUN-$STAMP.log"

# shellcheck source=infra/claudebox/lib.sh
. "$HERE/lib.sh"
install_run_trap

# The playbook and skills are read from this checkout, so it must match
# origin — a stale or dirty checkout stops the run (see lib.sh).
RUN_STAGE="sync"
sync_checkout
require_claude_login

TOKEN_FILE="$CFG_DIR/kp-token"
[ -r "$TOKEN_FILE" ] || fail "$TOKEN_FILE missing (see infra/claudebox/README.md)"
KP_DIGEST_TOKEN="$(cat "$TOKEN_FILE")"
export KP_DIGEST_TOKEN
export KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.bastla.com}"

ALLOWED="$(grep -vE '^\s*(#|$)' "$HERE/allowed-tools-weekly.txt" | paste -sd, -)"

PROMPT="$(cat "$REPO/skills/kulturni-prehled/claudebox-routine.md")
Repo checkout: $REPO. Today (UTC): $STAMP."

echo "[$(date -u +%FT%TZ)] launching kulturni-prehled weekly; log=$LOG"
RUN_STAGE="claude"
# --permission-mode dontAsk: only allowed-tools-weekly.txt is approved. The
# box's synced settings default to `auto`, where a classifier would approve
# anything else and the list would be advice, not a boundary (2026-09-30).
# `< /dev/null`: claude -p reads stdin and blocks on an inherited pipe or TTY
# (the Ústředna supervisor hung 5+ h on one on 2026-08-10).
claude -p "$PROMPT" \
  --permission-mode dontAsk \
  --allowedTools "$ALLOWED" \
  --add-dir "$REPO" \
  --output-format text \
  < /dev/null \
  2>&1 | tee "$LOG"

RUN_STAGE="done"
echo "[$(date -u +%FT%TZ)] weekly run finished; report in $LOG"
# The exit trap now parks anything the agent left in the checkout.
