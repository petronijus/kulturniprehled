#!/usr/bin/env bash
# Checks this machine against the toolchain pinned in AGENTS.md and prints
# the fix for anything missing. Exit 1 when something required is wrong.
# `check && ok … || bad …` is if/else here: ok and warn only print.
# shellcheck disable=SC2015
set -uo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

FLUTTER="$(tr -d "[:space:]" <"$root/.flutter-version")" # also enforced by pubspec.yaml
JAVA_MAJOR=25
JAVA_MIN=17
ANDROID_PLATFORM=android-36
NODE_MAJOR=22

fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n      → %s\n' "$1" "$2"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n      → %s\n' "$1" "$2"; }
has() { command -v "$1" >/dev/null 2>&1; }

echo "Toolchain"
if has flutter; then
  v="$(flutter --version --machine 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["frameworkVersion"])')"
  [[ "$v" == "$FLUTTER" ]] && ok "Flutter $v" \
    || bad "Flutter $v (want $FLUTTER: 3.44 moved Cupertino transitions out of material.dart, 3.47 fixed iOS simulator builds on Xcode 27)" \
      "cd \$(dirname \$(dirname \$(command -v flutter))) && git fetch --tags && git checkout $FLUTTER"
  flutter config --list 2>/dev/null | grep -q "enable-swift-package-manager: false" \
    && ok "Swift Package Manager disabled" \
    || bad "Swift Package Manager enabled (workmanager_apple, flutter_secure_storage and flutter_local_notifications ship only CocoaPods specs)" \
      "flutter config --no-enable-swift-package-manager"
else
  bad "flutter missing" "install Flutter $FLUTTER (git checkout of the tag)"
fi

v="$(java -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -1)"
fix="install JDK $JAVA_MAJOR (brew install openjdk@$JAVA_MAJOR) and point JAVA_HOME, PATH and flutter config --jdk-dir at it"
if [[ -z "$v" ]]; then bad "no JDK on PATH" "$fix"
elif ((v < JAVA_MIN)); then bad "JDK $v (AGP 9.2 needs ≥ $JAVA_MIN)" "$fix"
elif [[ "$v" == "$JAVA_MAJOR" ]]; then ok "JDK $v"
else warn "JDK $v (the machines share JDK $JAVA_MAJOR with Pinkni)" "$fix"; fi

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -n "$sdk" && -d "$sdk/platforms/$ANDROID_PLATFORM" ]]; then ok "Android SDK $ANDROID_PLATFORM"
else bad "Android SDK $ANDROID_PLATFORM missing (Flutter $FLUTTER's default compileSdk)" \
  "sdkmanager \"platforms;$ANDROID_PLATFORM\" (ANDROID_HOME must be set)"; fi

if has node; then
  v="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
  [[ "$v" == "$NODE_MAJOR" ]] && ok "Node $(node --version)" \
    || bad "Node $(node --version) (want $NODE_MAJOR: the API image builds the planner SPA on node:$NODE_MAJOR-slim)" \
      "install Node $NODE_MAJOR (brew install node@$NODE_MAJOR, or nvm use in apps/api/web)"
else
  bad "node missing" "install Node $NODE_MAJOR (brew install node@$NODE_MAJOR)"
fi

if has docker && docker info >/dev/null 2>&1; then ok "Docker $(docker info --format '{{.ServerVersion}}')"
elif has docker; then bad "Docker daemon not reachable (pytest runs Postgres and MinIO in testcontainers)" \
  "start Docker (Linux: sudo systemctl start docker; macOS: open the Docker app)"
else bad "docker missing (pytest runs Postgres and MinIO in testcontainers)" "install Docker"; fi

if [[ "$(uname)" == Darwin ]]; then
  has xcodebuild && ok "$(xcodebuild -version | head -1)" || bad "Xcode missing" "install Xcode from the App Store"
  xcrun --find swift-format >/dev/null 2>&1 && ok "swift-format (Xcode)" || bad "swift-format missing" "update Xcode"
  has pod && ok "CocoaPods $(pod --version)" || bad "CocoaPods missing" "brew install cocoapods"
else
  warn "not macOS" "iOS builds need the MacBook or the MacOS VM"
fi

echo "Dev tools"
for t in just lefthook gitleaks python3 uv ktlint shellcheck; do
  has "$t" && ok "$t" || bad "$t missing" "brew install $t   (Linux: see docs/development.md)"
done

echo "Project"
[[ -x "$root/.git/hooks/pre-commit" ]] && grep -q lefthook "$root/.git/hooks/pre-commit" \
  && ok "git hooks installed" || warn "git hooks not installed" "lefthook install"
patterns="${KP_PII_PATTERNS:-$HOME/.claude/skills/repo-hygiene/patterns.txt}"
[[ -f "$patterns" ]] && ok "PII patterns ($patterns)" \
  || warn "PII patterns missing: the pre-commit PII scan is skipped" "set KP_PII_PATTERNS or sync ai-config (repo-hygiene skill)"
[[ -d "$root/private/.git" ]] && ok "private overlay (private/)" \
  || warn "private overlay missing: release, deploy and secrets recipes need it" \
    "git clone https://github.com/petronijus/kulturniprehled-private.git private"

exit $fail
