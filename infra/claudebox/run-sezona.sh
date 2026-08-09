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

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CFG_DIR="${CFG_DIR:-$HOME/.config/kulturni-prehled}"
LOGDIR="$CFG_DIR/logs"; mkdir -p "$LOGDIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/sezona-$STAMP.log"

git -C "$REPO" pull --ff-only -q || echo "[warn] git pull failed, running on the existing checkout"

KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --account my --fields label=credential --reveal)"
[ -n "$KP_TOKEN" ] || { echo "FATAL: could not fetch the KP PAT from 1Password"; exit 1; }
export KP_TOKEN
export KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.bastla.com}"

ICS_FILE="$CFG_DIR/calendar-ics-url"
if [ -r "$ICS_FILE" ]; then
  KP_CALENDAR_ICS_URL="$(cat "$ICS_FILE")"
  export KP_CALENDAR_ICS_URL
fi

ALLOWED="$(grep -vE '^\s*(#|$)' "$HERE/allowed-tools-weekly.txt" | paste -sd, -)"

PROMPT="$(cat "$REPO/skills/kulturni-sezona/SKILL.md")

Claudebox substitutions for this run: the KP token is already in
\$KP_TOKEN (do not use op yourself, never print it). No Spotify and no
google-workspace MCP here — skip Spotify (missing_sources) and build
blocked.json from \$KP_CALENDAR_ICS_URL per
skills/kulturni-prehled/claudebox-routine.md 'Calendar via ICS' (unset →
empty blocked set, note it in the report). Experts run via the Skill
tool in season mode; scrapers and kp_validate.py run natively from the
checkout at $REPO. Today (UTC): $STAMP."

echo "[$(date -u +%FT%TZ)] launching kulturni-sezona; log=$LOG"
claude -p "$PROMPT" \
  --allowedTools "$ALLOWED" \
  --add-dir "$REPO" \
  --output-format text \
  2>&1 | tee "$LOG"

echo "[$(date -u +%FT%TZ)] season run finished; report in $LOG"
