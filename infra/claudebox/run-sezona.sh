#!/usr/bin/env bash
# Manual season-planning run on the claudebox (once per season, or to
# refresh the pool + scenarios). Interactive on purpose: fetches the FULL
# KP PAT from 1Password (the season orchestrator reads /v1/events history,
# which the weekly scoped token deliberately cannot) — run via `ssh -t` so
# `op` can prompt.
#
#   ssh -t petronijus@server-linux.home.arpa \
#     '~/Documents/Dev/kulturniprehled/infra/claudebox/run-sezona.sh'
#
#   run-sezona.sh --rehearsal   # the same session and boundary, WITHOUT the
#                               # KP token (nothing can be written to the API,
#                               # no 1Password prompt) and with a short probe
#                               # checklist instead of the season run
set -euo pipefail
REHEARSAL=""
[ "${1:-}" = "--rehearsal" ] && REHEARSAL=1

# Manual ssh runs come in with a bare non-login PATH — make claude et al.
# resolvable regardless of how we were invoked.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CFG_DIR="${CFG_DIR:-$HOME/.config/kulturni-prehled}"
LOGDIR="$CFG_DIR/logs"; mkdir -p "$LOGDIR"
RUN="sezona${REHEARSAL:+-rehearsal}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/$RUN-$STAMP.log"

# shellcheck source=infra/claudebox/lib.sh
. "$HERE/lib.sh"
install_run_trap

RUN_STAGE="sync"
sync_checkout
# The sync may have just replaced this very file. bash reads a script as it
# runs, so carrying on would execute the new file's bytes from the old
# file's offset, or finish as the old script (2026-10-10: `--rehearsal` was
# pulled in mid-run, and the old script, which did not know the flag, went
# on to start a real weekly session). Start over from the synced
# copy; the second sync is a no-op. exec skips the exit trap on purpose.
[ -n "${KP_SYNCED:-}" ] || KP_SYNCED=1 exec "$HERE/run-sezona.sh" "$@"
require_claude_login

export KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.bastla.com}"
if [ -z "$REHEARSAL" ]; then
  RUN_STAGE="token"
  KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --account my --fields label=credential --reveal)"
  [ -n "$KP_TOKEN" ] || fail "could not fetch the KP PAT from 1Password"
  export KP_TOKEN

  PROMPT="$(cat "$REPO/skills/kulturni-sezona/SKILL.md")

Claudebox substitutions for this run: the KP token is already in
\$KP_TOKEN (do not use op yourself, never print it). No Spotify and no
google-workspace MCP here — skip Spotify (missing_sources); blocked.json
comes from GET /v1/season/calendar exactly as SKILL.md step 1 says
(available:false → empty blocked set, note it in the report). Experts run via the Skill
tool in season mode — the KP skills are the plugin \`kp\`, so call them as
kp:<name> (kp:klasika-expert, …); scrapers and kp_validate.py run natively from the
checkout at $REPO. Edits to that checkout do not outlive this run (the
runner saves them as a patch and stashes them), so report every one — file,
what was wrong, how it was verified — and never leave work there for
approval. Today (UTC): $STAMP."
else
  unset KP_TOKEN KP_DIGEST_TOKEN
  PROMPT="$(rehearsal_prompt sezona)"
fi

RUN_STAGE="session"
prepare_session

echo "[$(date -u +%FT%TZ)] launching kulturni-sezona $RUN; log=$LOG"
RUN_STAGE="claude"
run_session "$PROMPT" 2>&1 | tee "$LOG"

RUN_STAGE="done"
echo "[$(date -u +%FT%TZ)] season run finished; report in $LOG"
