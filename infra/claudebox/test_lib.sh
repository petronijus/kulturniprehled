#!/usr/bin/env bash
# Tests for lib.sh — no network, no claude, no box. A throwaway bare repo plays
# origin, a fake `claude` plays the CLI, and a notify hook records alerts.
#
#   infra/claudebox/test_lib.sh

# Snippets passed to run_with_lib expand in the child shell, on purpose.
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
ok()   { pass=$((pass + 1)); echo "ok   - $*"; }
fail_test() { echo "FAIL - $*" >&2; exit 1; }

git_q() { git -c user.name=test -c user.email=test@example.invalid "$@" -q; }

# origin with one commit, a clone that tracks it, a second clone to push from
setup() {
  rm -rf "$T/case"; mkdir -p "$T/case"
  git init -q --bare -b main "$T/case/origin.git"
  git_q clone "$T/case/origin.git" "$T/case/upstream" 2>/dev/null
  echo one >"$T/case/upstream/file.txt"
  git -C "$T/case/upstream" add file.txt
  git_q -C "$T/case/upstream" commit -m one
  git_q -C "$T/case/upstream" push origin HEAD:main
  git_q clone "$T/case/origin.git" "$T/case/repo"

  mkdir -p "$T/case/cfg/logs" "$T/case/bin"
  cat >"$T/case/cfg/notify" <<'EOF'
#!/usr/bin/env bash
{ echo "SUBJECT: $1"; cat; echo "---"; } >>"$(dirname "$0")/alerts"
EOF
  chmod +x "$T/case/cfg/notify"
}

push_upstream_change() {
  echo "$1" >"$T/case/upstream/file.txt"
  git_q -C "$T/case/upstream" commit -am "$1"
  git_q -C "$T/case/upstream" push origin HEAD:main
}

# Run a snippet in a fresh shell with lib.sh sourced, the way run-*.sh do.
run_with_lib() {
  env PATH="$T/case/bin:$PATH" REPO="$T/case/repo" CFG_DIR="$T/case/cfg" \
    LOGDIR="$T/case/cfg/logs" RUN=test STAMP=20260101T000000Z \
    LOG="$T/case/cfg/logs/test.log" LIB="$LIB" \
    bash -c 'set -euo pipefail; . "$LIB"; '"$1"
}

alerts() { cat "$T/case/cfg/alerts" 2>/dev/null || true; }

# 1. a clean checkout behind origin fast-forwards, no alert
setup
push_upstream_change two
run_with_lib 'sync_checkout' >/dev/null
[ "$(cat "$T/case/repo/file.txt")" = two ] || fail_test "clean checkout did not fast-forward"
[ -z "$(alerts)" ] || fail_test "clean sync raised an alert"
ok "clean checkout fast-forwards silently"

# 2. the 2026-09 case: a local edit to a file upstream also changed
setup
echo local-fix >"$T/case/repo/file.txt"
echo scratch >"$T/case/repo/untracked.txt"
push_upstream_change upstream-fix
run_with_lib 'sync_checkout' >/dev/null
[ "$(cat "$T/case/repo/file.txt")" = upstream-fix ] || fail_test "dirty checkout did not reach origin"
[ -z "$(git -C "$T/case/repo" status --porcelain)" ] || fail_test "checkout not clean after sync"
patch="$T/case/cfg/logs/test-20260101T000000Z-pre-run.patch"
grep -q '^+local-fix' "$patch" || fail_test "patch lacks the tracked edit"
grep -q '^+scratch' "$patch" || fail_test "patch lacks the untracked file"
git -C "$T/case/repo" stash list | grep -q 'run-test 20260101T000000Z: left in the checkout (pre-run)' \
  || fail_test "stash missing"
alerts | grep -q 'SUBJECT: kulturni-prehled test: changes left in the claudebox checkout' \
  || fail_test "no alert for parked changes"
ok "dirty checkout is parked (patch + stash + alert) and synced"

# 3. local commits that cannot fast-forward stop the run with a reason
setup
echo diverged >"$T/case/repo/file.txt"
git_q -C "$T/case/repo" commit -am diverged
push_upstream_change elsewhere
if out="$(run_with_lib 'sync_checkout; echo SHOULD-NOT-REACH' 2>&1)"; then
  fail_test "diverged checkout did not fail"
fi
case "$out" in *SHOULD-NOT-REACH*) fail_test "run continued past a failed sync" ;; esac
case "$out" in *"cannot fast-forward"*) ;; *) fail_test "no reason given: $out" ;; esac
ok "diverged checkout fails the run"

# 4. not logged in → the run fails before it starts, and the trap alerts
setup
printf '#!/bin/sh\necho %s\n' "'{\"loggedIn\": false}'" >"$T/case/bin/claude"
chmod +x "$T/case/bin/claude"
if run_with_lib 'install_run_trap; RUN_STAGE=sync; require_claude_login' >/dev/null 2>&1; then
  fail_test "missing login did not fail"
fi
alerts | grep -q 'SUBJECT: kulturni-prehled test run failed (sync)' || fail_test "no failure alert"
alerts | grep -q 'Reason:.*not logged in' || fail_test "failure alert lacks the reason"
ok "missing login fails early with an alert"

# 5. logged in → passes
printf '#!/bin/sh\necho %s\n' "'{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}'" >"$T/case/bin/claude"
run_with_lib 'require_claude_login' || fail_test "valid login rejected"
ok "valid login passes"

# 6. whatever the agent leaves behind is parked after the run, even on success
setup
run_with_lib 'install_run_trap; RUN_STAGE=claude; echo agent-edit >"$REPO/file.txt"; RUN_STAGE=done' >/dev/null
[ -z "$(git -C "$T/case/repo" status --porcelain)" ] || fail_test "agent edit not parked"
grep -q '^+agent-edit' "$T/case/cfg/logs/test-20260101T000000Z-post-run.patch" || fail_test "post-run patch missing"
alerts | grep -q 'failed' && fail_test "successful run raised a failure alert"
ok "post-run edits are parked on a successful run"

# 7. a crash mid-run parks the edits AND reports the failure
setup
if run_with_lib 'install_run_trap; RUN_STAGE=claude; echo half-done >"$REPO/file.txt"; exit 3' >/dev/null 2>&1; then
  fail_test "crash exit status lost"
fi
[ -z "$(git -C "$T/case/repo" status --porcelain)" ] || fail_test "crash left the tree dirty"
alerts | grep -q 'SUBJECT: kulturni-prehled test run failed (claude)' || fail_test "crash not alerted"
alerts | grep -q 'exited with status 3' || fail_test "crash alert lacks the status"
ok "a crash parks edits and alerts with the exit status"

# 8. no hook installed: alert goes to stderr, nothing breaks
setup
rm "$T/case/cfg/notify"
echo x >"$T/case/repo/file.txt"
out="$(run_with_lib 'sync_checkout' 2>&1)" || fail_test "sync failed without a hook"
case "$out" in *"no notify hook"*) ;; *) fail_test "missing hook not reported: $out" ;; esac
ok "missing notify hook is reported, not fatal"

# 9. prepare_session builds the sandboxed settings and the kp plugin from the
#    real lists; the exit trap removes both
setup
while IFS= read -r skill; do
  case "$skill" in '' | '#'*) continue ;; esac
  mkdir -p "$T/case/repo/skills/$skill"
  echo "# $skill" >"$T/case/repo/skills/$skill/SKILL.md"
done <"$HERE/session-skills.txt"
out="$(run_with_lib 'install_run_trap; KP_API_BASE=https://kp.example.com; prepare_session; echo "TMP=$SESSION_TMP";
  python3 -c "import json,sys; s=json.load(open(sys.argv[1]))[\"sandbox\"]; assert s[\"enabled\"] and s[\"failIfUnavailable\"] and not s[\"allowUnsandboxedCommands\"]" "$SESSION_SETTINGS";
  echo SANDBOX-OK;
  python3 -c "import json,sys; print(\"DOMAINS=\" + \",\".join(json.load(open(sys.argv[1]))[\"sandbox\"][\"network\"][\"allowedDomains\"]))" "$SESSION_SETTINGS";
  cat "$SESSION_PLUGIN/.claude-plugin/plugin.json";
  readlink "$SESSION_PLUGIN/skills/klasika-expert"')" || fail_test "prepare_session failed: $out"
case "$out" in *SANDBOX-OK*) ;; *) fail_test "settings lack the fail-closed sandbox: $out" ;; esac
case "$out" in *DOMAINS=*kp.example.com*) ;; *) fail_test "KP_API_BASE host not allowed: $out" ;; esac
case "$out" in *'"name": "kp"'*) ;; *) fail_test "plugin manifest missing: $out" ;; esac
case "$out" in *"$T/case/repo/skills/klasika-expert"*) ;; *) fail_test "skill not linked from the checkout: $out" ;; esac
session_tmp="$(printf '%s\n' "$out" | sed -n 's/^TMP=//p')"
[ -n "$session_tmp" ] && [ ! -e "$session_tmp" ] || fail_test "session dir not removed on exit: $session_tmp"
ok "prepare_session builds a fail-closed sandbox and the kp plugin; exit removes them"

# 10. a skill named in session-skills.txt but missing in the checkout stops the run
setup
if run_with_lib 'install_run_trap; RUN_STAGE=session; KP_API_BASE=https://kp.example.com; prepare_session' >/dev/null 2>&1; then
  fail_test "missing skill did not fail"
fi
alerts | grep -q 'Reason:.*session-skills.txt names' || fail_test "missing skill not alerted with its reason"
ok "a missing skill fails the run with an alert"

# 11. the rehearsal prompt never carries a token and names the refusals it checks
out="$(run_with_lib 'rehearsal_prompt weekly')"
case "$out" in *'kp:kulturni-prehled'*'~/.config/gh/hosts.yml'*'git ls-remote https://github.com/'*) ;;
  *) fail_test "weekly rehearsal prompt incomplete" ;; esac
case "$(run_with_lib 'rehearsal_prompt sezona')" in *'kp:kulturni-sezona'*) ;;
  *) fail_test "sezona rehearsal prompt does not load its skill" ;; esac
ok "rehearsal prompts probe the skills and the refusals"

echo "all $pass passed"
