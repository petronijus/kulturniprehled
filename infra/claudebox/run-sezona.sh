#!/usr/bin/env bash
# Manual season-planning run on the claudebox (once per season, or to
# refresh the pool + scenarios). Interactive on purpose: fetches the FULL
# KP PAT from 1Password (the season orchestrator reads /v1/events history,
# which the weekly scoped token deliberately cannot) — run via `ssh -t` so
# `op` can prompt.
#
#   ssh -t petronijus@server-linux.home.arpa \
#     '~/Documents/Dev/kulturniprehled/infra/claudebox/run-sezona.sh'
set -euo pipefail

# Manual ssh runs come in with a bare non-login PATH — make claude et al.
# resolvable regardless of how we were invoked.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CFG_DIR="${CFG_DIR:-$HOME/.config/kulturni-prehled}"
LOGDIR="$CFG_DIR/logs"; mkdir -p "$LOGDIR"
RUN="sezona"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/$RUN-$STAMP.log"

# shellcheck source=infra/claudebox/lib.sh
. "$HERE/lib.sh"
install_run_trap

RUN_STAGE="sync"
sync_checkout
require_claude_login

RUN_STAGE="token"
KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --account my --fields label=credential --reveal)"
[ -n "$KP_TOKEN" ] || fail "could not fetch the KP PAT from 1Password"
export KP_TOKEN
export KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.bastla.com}"

ALLOWED="$(grep -vE '^\s*(#|$)' "$HERE/allowed-tools-weekly.txt" | paste -sd, -)"

PROMPT="$(cat "$REPO/skills/kulturni-sezona/SKILL.md")

Claudebox substitutions for this run: the KP token is already in
\$KP_TOKEN (do not use op yourself, never print it). No Spotify and no
google-workspace MCP here — skip Spotify (missing_sources); blocked.json
comes from GET /v1/season/calendar exactly as SKILL.md step 1 says
(available:false → empty blocked set, note it in the report). Experts run via the Skill
tool in season mode; scrapers and kp_validate.py run natively from the
checkout at $REPO. Edits to that checkout do not outlive this run (the
runner saves them as a patch and stashes them), so report every one — file,
what was wrong, how it was verified — and never leave work there for
approval. Today (UTC): $STAMP."

echo "[$(date -u +%FT%TZ)] launching kulturni-sezona; log=$LOG"
RUN_STAGE="claude"
claude -p "$PROMPT" \
  --allowedTools "$ALLOWED" \
  --add-dir "$REPO" \
  --output-format text \
  2>&1 | tee "$LOG"

RUN_STAGE="done"
echo "[$(date -u +%FT%TZ)] season run finished; report in $LOG"
