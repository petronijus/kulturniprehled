# shellcheck shell=bash
# Shared plumbing for the headless claudebox runs (run-weekly.sh, run-sezona.sh).
# Sourced, never executed. The caller sets, before sourcing:
#   REPO      the checkout the run reads its playbook and skills from
#   CFG_DIR   ~/.config/kulturni-prehled
#   LOGDIR    where run logs live
#   RUN       short run name ("weekly", "sezona") — used in file names and alerts
#   STAMP     UTC timestamp of this run
#   LOG       this run's log file
#
# Why this exists: the checkout is not a scratch copy. ~/.claude/skills links
# into it, so whatever sits in its working tree IS the code the next run loads.
# On 2026-09-05 a weekly run fixed a scraper bug in place and left the edit
# uncommitted. The same fix then landed upstream in a different shape, every
# later `git pull --ff-only` refused to overwrite the local edit, and the run
# script only printed "[warn] git pull failed" to a journal nobody reads — so
# three weekly runs went out on a checkout frozen at 2026-08-31.
#
# The rules that follow from it:
#   * The working tree is clean before a run starts and after it ends. Anything
#     a run leaves behind is saved as a patch next to the log, stashed (so it is
#     recoverable, never discarded), and reported.
#   * A checkout that cannot be brought to origin is a failed run, not a
#     warning. Running stale code quietly is the failure mode being removed.
#   * Every failure reaches a human through the notify hook.

# fail <reason>  — record why the run is stopping (the exit alert quotes it)
# and return non-zero, so callers can write `step || fail "…" || return 1`.
FAIL_REASON=""
fail() {
  FAIL_REASON="$*"
  echo "[$(date -u +%FT%TZ)] FATAL: $*"
  return 1
}

# notify <subject>  — Markdown body on stdin.
# Delivered by the optional executable $CFG_DIR/notify with the same contract.
# Without a hook the alert still lands in the journal, loudly.
notify() {
  local subject="$1" hook="$CFG_DIR/notify"
  if [ -x "$hook" ]; then
    "$hook" "$subject" || echo "[$(date -u +%FT%TZ)] ALERT DELIVERY FAILED: $subject" >&2
  else
    cat >/dev/null
    echo "[$(date -u +%FT%TZ)] ALERT (no notify hook at $hook, nobody was told): $subject" >&2
  fi
}

# park_changes <when>  — if the working tree is dirty, save it as a patch in
# $LOGDIR, stash it (untracked files included) and alert. <when> is "pre-run"
# or "post-run" and only labels the files and the alert.
park_changes() {
  local when="$1" status patch msg
  status="$(git -C "$REPO" status --porcelain)" || return 1
  [ -n "$status" ] || return 0

  patch="$LOGDIR/$RUN-$STAMP-$when.patch"
  msg="run-$RUN $STAMP: left in the checkout ($when)"
  git -C "$REPO" stash push --include-untracked -q -m "$msg" || return 1
  git -C "$REPO" stash show -p --binary --include-untracked 'stash@{0}' >"$patch" || return 1
  echo "[$(date -u +%FT%TZ)] parked uncommitted changes ($when): $patch"

  notify "kulturni-prehled $RUN: changes left in the claudebox checkout" <<EOF
The $RUN run found uncommitted changes in \`$REPO\` ($when) and moved them out
of the way so the checkout keeps tracking origin.

\`\`\`
$status
\`\`\`

- Patch: \`$patch\`
- Stash: \`$msg\` (\`git -C $REPO stash list\`)

If the change is worth keeping, commit it upstream; the box picks it up on
the next run. Run log: \`$LOG\`
EOF
}

# sync_checkout  — bring the checkout to its upstream branch or fail.
sync_checkout() {
  park_changes pre-run || fail "could not park the dirty checkout at $REPO" || return 1
  git -C "$REPO" fetch -q || fail "git fetch failed in $REPO" || return 1
  git -C "$REPO" merge --ff-only -q '@{upstream}' \
    || fail "$REPO cannot fast-forward to its upstream (local commits?)" || return 1
  echo "[$(date -u +%FT%TZ)] checkout at $(git -C "$REPO" log -1 --format='%h %s')"
}

# require_claude_login  — a lapsed `claude auth login` blanks its credential
# file and every run then dies within a second. Say so before starting.
require_claude_login() {
  claude auth status 2>/dev/null | grep -q '"loggedIn": *true' \
    || fail "claude is not logged in on this box — run \`claude auth login\` (or /login in the tmux session)"
}

# prepare_session  — build what the headless session runs inside, in a
# throwaway directory under $CFG_DIR that the exit trap removes:
#   * the --settings file (session_settings.py): permissions from
#     allowed-tools-weekly.txt and denied-tools.txt, and the Bash sandbox
#     (bubblewrap) bounded by them and sandbox-domains.txt;
#   * the `kp` plugin carrying the skills of session-skills.txt, linked from
#     the checkout — restricted mode does not load ~/.claude/skills, so the
#     session finds them as kp:<name>.
# Sets SESSION_SETTINGS and SESSION_PLUGIN. Run it in the main shell (not in a
# pipeline), so a failure reaches the exit alert with its reason.
SESSION_TMP=""
SESSION_SETTINGS=""
SESSION_PLUGIN=""
prepare_session() {
  local here skill
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SESSION_TMP="$(mktemp -d "$CFG_DIR/session-$STAMP.XXXXXX")" \
    || fail "could not create the session directory in $CFG_DIR" || return 1
  SESSION_SETTINGS="$SESSION_TMP/settings.json"
  SESSION_PLUGIN="$SESSION_TMP/plugin"
  # The scrapers' page cache (skills/lib/kp_fetch.py), writable in the
  # sandbox; it has to exist before the sandbox can mount it.
  mkdir -p "$HOME/.cache/kulturni-prehled"
  # The KP API host comes from $KP_API_BASE; private hosts beyond it live in
  # the box-local sandbox-domains.local, never in this public repo.
  local domains=(--domains "$here/sandbox-domains.txt")
  [ ! -f "$CFG_DIR/sandbox-domains.local" ] || domains+=(--domains "$CFG_DIR/sandbox-domains.local")
  python3 "$here/session_settings.py" \
    --allowed "$here/allowed-tools-weekly.txt" --denied "$here/denied-tools.txt" \
    "${domains[@]}" --url "${KP_API_BASE:?KP_API_BASE must be set before prepare_session}" \
    --home "$HOME" --repo "$REPO" \
    >"$SESSION_SETTINGS" || fail "session_settings.py could not build the session settings" || return 1
  mkdir -p "$SESSION_PLUGIN/.claude-plugin" "$SESSION_PLUGIN/skills"
  printf '%s\n' '{"name": "kp", "version": "1.0.0", "description": "Kulturni prehled skills for the headless claudebox runs"}' \
    >"$SESSION_PLUGIN/.claude-plugin/plugin.json"
  while IFS= read -r skill; do
    case "$skill" in '' | '#'*) continue ;; esac
    [ -f "$REPO/skills/$skill/SKILL.md" ] \
      || fail "session-skills.txt names $skill, but $REPO/skills/$skill/SKILL.md is missing" || return 1
    ln -s "$REPO/skills/$skill" "$SESSION_PLUGIN/skills/$skill"
  done <"$here/session-skills.txt"
}

# run_session <prompt>  — the headless session, after prepare_session. Its
# output goes to stdout (the caller tees it into $LOG).
#   --restricted: the box's user, project and local settings are NOT loaded
#     (before 2026-10-10 the allow-list only added to the synced user
#     allow-list and hooks); file tools stay in the working directories.
#   --settings: the only permissions, and the sandbox: Bash runs in
#     bubblewrap — writes only to the checkout and /tmp, no reads of the
#     denied places, network only to sandbox-domains.txt, no unsandboxed
#     retry, and no run at all if the sandbox cannot start.
#   --strict-mcp-config: no MCP servers, the claude.ai connectors included.
#   --add-dir /tmp: the work dirs (/tmp/kp-digest-CW<n>, /tmp/kp-season-…).
#   `< /dev/null`: claude -p reads stdin and blocks on an inherited pipe or
#     TTY (the Ústředna supervisor hung 5+ h on one on 2026-08-10).
run_session() {
  (cd "$REPO" && claude -p "$1" \
    --restricted --strict-mcp-config \
    --tools "Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,Skill,TodoWrite,ToolSearch" \
    --settings "$SESSION_SETTINGS" \
    --plugin-dir "$SESSION_PLUGIN" \
    --permission-mode dontAsk \
    --add-dir /tmp \
    --output-format text \
    </dev/null)
}

# rehearsal_prompt <weekly|sezona>  — the probe checklist a --rehearsal runs
# instead of the routine: everything a real run leans on (skills, heredocs,
# the API host, a scraper host, the validator, WebFetch, file tools in /tmp) and
# what the boundary must refuse. Without a KP token in the environment the
# API answers 401, so a rehearsal can neither send, ack nor write.
rehearsal_prompt() {
  local mode_skill="kp:kulturni-prehled" work="/tmp/kp-rehearsal-$STAMP"
  [ "$1" = sezona ] && mode_skill="kp:kulturni-sezona"
  cat <<EOF
REHEARSAL of the headless kulturni-prehled $1 session — NOT a run. Do not
follow any skill's procedure. There is no KP token; never look for one. Do
exactly this, each numbered item as its own tool call, and record whether it
worked, failed (quote the error) or was denied (quote the denial):
1. Skill tool: $mode_skill, then kp:klasika-expert — only confirm each loads.
2. Bash: mkdir -p $work && cd $work && python3 - <<'PY'
   (a heredoc printing "heredoc ok" and writing probe.json with json.dump)
   followed by: echo "now \$(date -u +%H:%M)"; for i in 1 2; do echo loop\$i; done
3. Write tool: $work/note.txt with one line; then Read it back.
4. Bash: curl -sS -o /dev/null -w '%{http_code}' -A 'kp-skill/1.0' "\$KP_API_BASE/v1/season/plans/current"
   (expected 401: the host is reachable, the request is unauthenticated)
5. Bash: python3 skills/lib/kp_fetch.py get --kind listing https://www.ceskafilharmonie.cz/program | wc -c
   then the same command again, and python3 skills/lib/kp_fetch.py status
   (the scrapers' page cache: the first call may fetch or revalidate, the
   second must say "KP_FETCH cached" — the cache is writable in the sandbox.
   Never run a whole scraper in a rehearsal: fok.cz bans this network after
   a burst, see skills/lib/kp_fetch.py)
6. Bash: python3 skills/kulturni-sezona/bin/kp_validate.py --help | head -3
7. WebFetch https://www.rudolfinum.cz/ — the page title only.
Expected to be refused (report how each one failed):
8. Bash: cat ~/.config/gh/hosts.yml
9. Bash: ls ~/Documents/Dev/ai-config
10. Bash: echo x > ~/kp-escape.txt
11. Bash: curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://example.com/
12. Bash: git ls-remote https://github.com/petronijus/kulturniprehled.git HEAD
End with a table of the steps and their outcomes as your final message.
EOF
}

# install_run_trap  — on exit, park whatever the run left behind and alert on
# failure with the tail of the log. Set RUN_STAGE as the run progresses so the
# alert says where it stopped; post-run parking only happens once the agent
# has actually run ("claude" or later).
RUN_STAGE="setup"
_on_run_exit() {
  local rc=$?
  [ -z "$SESSION_TMP" ] || rm -rf "$SESSION_TMP"
  if [ "$RUN_STAGE" = "claude" ] || [ "$RUN_STAGE" = "done" ]; then
    park_changes post-run || echo "[$(date -u +%FT%TZ)] could not park post-run changes in $REPO" >&2
  fi
  if [ "$rc" -ne 0 ]; then
    {
      echo "The $RUN run on the claudebox exited with status $rc during stage \`$RUN_STAGE\`."
      [ -z "$FAIL_REASON" ] || { echo; echo "**Reason:** $FAIL_REASON"; }
      echo
      echo '```'
      tail -n 40 "$LOG" 2>/dev/null || echo "(no log at $LOG)"
      echo '```'
    } | notify "kulturni-prehled $RUN run failed ($RUN_STAGE)"
  fi
}
install_run_trap() { trap _on_run_exit EXIT; }
