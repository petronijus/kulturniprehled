#!/usr/bin/env bash
# Format (or, with --check, verify) files by type. The single formatter entry
# point for `just fmt`, the lefthook pre-commit hook and the Claude Code
# PostToolUse hook, so all three agree.
#
#   tools/dev/format.sh [--check] <file>...
#   tools/dev/format.sh [--check] --all
#   tools/dev/format.sh --edit <file>...   (the Claude Code hook, after every edit)
#
# --edit leaves unused imports alone: an edit that adds an import usually
# comes before the edit that uses it. The pre-commit hook and `just check`
# still catch the ones that stay unused.
#
# Exit 1 when --check finds unformatted files, a linter reports something the
# formatter cannot fix, or a required formatter is missing.
# Plain bash 3.2 (macOS /bin/bash) compatible.
set -uo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root" || exit 1

web_dir=apps/api/web

check=false mid_edit=false
case "${1:-}" in
  --check) check=true; shift ;;
  --edit) mid_edit=true; shift ;;
esac

files=()
if [[ "${1:-}" == "--all" ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files --cached --others --exclude-standard \
    '*.dart' '*.swift' '*.kt' '*.kts' '*.py' '*.sh' \
    "$web_dir/*.ts" "$web_dir/*.tsx" "$web_dir/*.js" "$web_dir/*.mjs" "$web_dir/*.json" "$web_dir/*.css")
else
  files=("$@")
fi

dart=() swift=() kotlin=() python=() shell=() web=()
for f in ${files[@]+"${files[@]}"}; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.g.dart | *.freezed.dart | *.mocks.dart | */GeneratedPluginRegistrant.* | */generated/*) ;; # generated
    */node_modules/* | "$web_dir"/dist/* | */package-lock.json) ;;                                # generated
    *.dart) dart+=("$f") ;;
    *.swift) swift+=("$f") ;;
    *.kt | *.kts) kotlin+=("$f") ;;
    *.py) python+=("$f") ;;
    *.sh) shell+=("$f") ;;
    "$web_dir"/*.ts | "$web_dir"/*.tsx | "$web_dir"/*.js | "$web_dir"/*.mjs | "$web_dir"/*.json | "$web_dir"/*.css)
      web+=("${f#"$web_dir"/}") ;;
  esac
done

status=0
run() { "$@" || status=1; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "format.sh: $1 is required for $2 files (just doctor)" >&2; status=1; return 1; }; }

if ((${#dart[@]})) && need dart Dart; then
  if $check; then run dart format --output=none --set-exit-if-changed "${dart[@]}"
  else run dart format --show=none "${dart[@]}"; fi
fi

if ((${#swift[@]})); then
  if command -v xcrun >/dev/null && xcrun --find swift-format >/dev/null 2>&1; then
    config="apps/mobile/ios/.swift-format"
    if $check; then run xcrun swift-format lint --strict --configuration "$config" "${swift[@]}"
    else run xcrun swift-format format -i --configuration "$config" "${swift[@]}"; fi
  else
    echo "format.sh: swift-format needs Xcode; skipped ${#swift[@]} Swift file(s)" >&2
  fi
fi

if ((${#kotlin[@]})) && need ktlint Kotlin; then
  if $check; then run ktlint --relative "${kotlin[@]}"
  else run ktlint --relative -F "${kotlin[@]}"; fi
fi

# One ruff for every Python file: the version locked in apps/api/uv.lock.
# Each file still gets its closest config (apps/api/pyproject.toml, else ruff.toml).
if ((${#python[@]})) && need uv Python; then
  ruff=(uv run --quiet --frozen --project apps/api ruff)
  lint_opts=()
  if $mid_edit; then lint_opts=(--ignore F401); fi
  if $check; then
    run "${ruff[@]}" format --check --quiet "${python[@]}"
    run "${ruff[@]}" check --quiet "${python[@]}"
  else
    # Fix lint first (removing an import can leave lines only the formatter
    # cleans), format, then report only what is still wrong: a long line the
    # formatter has since split is not a complaint.
    "${ruff[@]}" check --fix --exit-zero --quiet ${lint_opts[@]+"${lint_opts[@]}"} "${python[@]}" >/dev/null
    run "${ruff[@]}" format --quiet "${python[@]}"
    run "${ruff[@]}" check --quiet ${lint_opts[@]+"${lint_opts[@]}"} "${python[@]}"
  fi
fi

# No shell formatter; shellcheck reports what needs a hand fix.
if ((${#shell[@]})) && need shellcheck shell; then
  run shellcheck "${shell[@]}"
fi

if ((${#web[@]})); then
  biome="$web_dir/node_modules/.bin/biome"
  if [[ -x "$biome" ]]; then
    if $check; then (cd "$web_dir" && node_modules/.bin/biome check --no-errors-on-unmatched "${web[@]}") || status=1
    else (cd "$web_dir" && node_modules/.bin/biome check --write --no-errors-on-unmatched "${web[@]}") || status=1; fi
  else
    echo "format.sh: $biome missing for ${#web[@]} web file(s); run \`just setup\` (npm ci)" >&2
    status=1
  fi
fi

exit $status
