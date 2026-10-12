#!/usr/bin/env bash
# The affected lane: `just check` narrowed to the units a change reaches,
# checked against the last working tree that passed this lane — the Claude
# Code Stop hook's check (`just check-affected`). pre-push keeps the whole
# `just check`.
#
# - formatting: the changed files only;
# - always (seconds): the docs check and shellcheck;
# - apps/mobile: Dart analyzer and tests;
# - apps/api/web: Biome, tsc and Vitest of the planner SPA;
# - apps/api (the rest): ruff, mypy and the API tests;
# - skills, infra/claudebox: ruff and the stdlib script tests;
# - any other Python file: ruff;
# - docs, Markdown, agent briefs and rules, other infra and scripts: covered
#   by the always-run checks above (`just check` checks nothing more there).
#
# Anything no unit owns — the justfile, tools/, .claude/hooks and settings,
# root config (ruff.toml, lefthook.yml, .editorconfig, .flutter-version),
# fonts/ — runs the whole `just check`: those reach every unit. So does a
# clone in which nothing has passed yet.
#
# Passes are recorded apart from the whole lane: the tree that passed is
# kept in the git dir (`claude-check-affected-base`), and the next run checks
# what changed since then. Sound step by step: each run covers every unit
# changed since a tree whose every unit had passed. pre-push reads nothing
# of it and runs the whole `just check` every time. bash 3.2 compatible.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$root" || exit 1
gitdir="$(git rev-parse --absolute-git-dir)" || exit 1
base_file="$gitdir/claude-check-affected-base"
lock="$gitdir/claude-check-affected.lock"

# The working tree as a tree object: HEAD plus every change and untracked
# (not ignored) file, written from a throwaway index.
tree_of() {
  local index start=HEAD tree ok
  index="$(mktemp "${TMPDIR:-/tmp}/kp-check-index.XXXXXX")" || return 1
  # Before the first commit there is no HEAD: start from the empty tree.
  git rev-parse -q --verify HEAD >/dev/null || start=--empty
  GIT_INDEX_FILE="$index" git read-tree "$start" &&
    GIT_INDEX_FILE="$index" git rm -r -q --cached --ignore-unmatch -- . &&
    GIT_INDEX_FILE="$index" git -c core.safecrlf=false add -A -- . &&
    tree="$(GIT_INDEX_FILE="$index" git write-tree)"
  ok=$?
  rm -f "$index"
  ((ok == 0)) || return 1
  echo "$tree"
}

# One run at a time per clone; a dead holder's lock is taken over.
take_lock() {
  local waited=0
  until mkdir "$lock" 2>/dev/null; do
    if [[ -f "$lock/pid" ]] && ! kill -0 "$(cat "$lock/pid")" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    ((waited == 0)) && echo "check-affected: another run holds $lock; waiting for it" >&2
    sleep 2
    waited=$((waited + 2))
    if ((waited > 900)); then
      echo "check-affected: gave up waiting for $lock" >&2
      return 1
    fi
  done
  echo $$ >"$lock/pid"
}

# Record the tree as passed, unless it changed during the run (then the next
# run simply checks again).
remember() {
  [[ "$(tree_of)" == "$1" ]] && echo "$1" >"$base_file"
  return 0
}

whole() {
  echo "check-affected: $1; running \`just check\`"
  just check || return 1
  [[ -n "${tree:-}" ]] && remember "$tree"
  return 0
}

recipes=()
want() {
  local r
  for r in "${recipes[@]+"${recipes[@]}"}"; do [[ "$r" == "$1" ]] && return; done
  recipes+=("$1")
}

main() {
  local base="" changed f files=() full="" r
  # A git failure must not read as "nothing changed": the whole lane, unrecorded.
  tree="$(tree_of)" || {
    tree=""
    whole "cannot write the working tree as a tree object"
    return
  }
  [[ -f "$base_file" ]] && base="$(cat "$base_file")"
  if [[ -z "$base" ]] || ! git cat-file -e "$base^{tree}" 2>/dev/null; then
    # Nothing passed yet in this clone (or a gc pruned its tree).
    whole "no earlier tree passed in this clone"
    return
  fi
  if ! changed="$(git diff --name-only --no-renames "$base" "$tree")"; then
    whole "cannot diff ${base:0:12}..${tree:0:12}"
    return
  fi
  if [[ -z "$changed" ]]; then
    echo "check-affected: nothing changed since the last tree that passed"
    return 0
  fi

  while IFS= read -r f; do
    [[ -e "$f" ]] && files+=("$f")
    case "$f" in
      apps/mobile/*) want lint-dart; want test-dart ;;
      apps/api/web/*) want lint-web; want test-web ;;
      apps/api/*) want lint-py; want test-api ;;
      skills/* | infra/claudebox/*) want lint-py; want test-scripts ;;
      *.md | docs/* | .claude/agents/* | .claude/rules/* | .claude/skills/*) ;;
      *.py) want lint-py ;;
      infra/* | scripts/* | assets-source/* | packages/*) ;;
      *)
        full="$f"
        break
        ;;
    esac
  done <<<"$changed"

  if [[ -n "$full" ]]; then
    whole "$full is shared by every unit"
    return
  fi

  echo "check-affected: $(echo "$changed" | wc -l | tr -d ' ') changed file(s) since ${base:0:12}"
  just _web-deps || return 1
  if ((${#files[@]} > 0)); then
    tools/dev/format.sh --check "${files[@]}" || return 1
  fi
  want lint-docs
  want lint-shell
  echo "check-affected: ${recipes[*]}"
  for r in "${recipes[@]}"; do
    just "$r" || return 1
  done
  remember "$tree"
}

take_lock || exit 1
trap 'rm -rf "$lock"' EXIT
main
