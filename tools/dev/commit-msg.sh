#!/usr/bin/env bash
# commit-msg hook: Conventional Commits (https://www.conventionalcommits.org).
#   type(scope)!: summary     e.g. `fix(ios): record delivered before the image download`
set -euo pipefail

subject="$(head -n1 "$1")"
types="feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert"

if [[ "$subject" =~ ^(Merge|Revert|fixup!|squash!|amend!) ]]; then exit 0; fi
if [[ "$subject" =~ ^($types)(\([a-z0-9,/._-]+\))?!?:\ .+ ]]; then
  if ((${#subject} > 72)); then
    echo "commit-msg: subject is ${#subject} characters; keep it within 72." >&2
    exit 1
  fi
  exit 0
fi

cat >&2 <<MSG
commit-msg: "$subject"
is not a Conventional Commit. Use  type(scope)!: summary
  types:  ${types//|/, }
  scopes: mobile, android, ios, api, web, season, skills, klasika, claudebox, infra, deploy, dev, … (optional)
MSG
exit 1
