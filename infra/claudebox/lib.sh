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

# install_run_trap  — on exit, park whatever the run left behind and alert on
# failure with the tail of the log. Set RUN_STAGE as the run progresses so the
# alert says where it stopped; post-run parking only happens once the agent
# has actually run ("claude" or later).
RUN_STAGE="setup"
_on_run_exit() {
  local rc=$?
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
