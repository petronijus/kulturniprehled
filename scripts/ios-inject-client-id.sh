#!/usr/bin/env bash
# Inject the real iOS Google OAuth client id into apps/mobile/ios/Runner/Info.plist.
#
# The committed Info.plist ships a `YOUR_IOS_CLIENT_ID` placeholder (the iOS
# OAuth client id can't come from --dart-define, it must be static in the plist).
# This swaps the placeholder for a real id before an iOS build, then you restore
# it afterwards so the placeholder stays in git.
#
# Source of the id (first match wins):
#   1. $KP_IOS_GOOGLE_CLIENT_ID in the environment
#   2. private/ios/build.env from the private overlay (maintainer convenience)
# Self-hosters: export KP_IOS_GOOGLE_CLIENT_ID="<your-bare-client-id>" (the part
# before .apps.googleusercontent.com) — see docs/SELF-HOSTING.md.
#
# Usage:
#   scripts/ios-inject-client-id.sh            # placeholder -> real id
#   scripts/ios-inject-client-id.sh --restore  # real id -> placeholder (git checkout)
set -euo pipefail
cd "$(dirname "$0")/.."
PLIST="apps/mobile/ios/Runner/Info.plist"

if [ "${1:-}" = "--restore" ]; then
  git checkout -- "$PLIST" && echo "Info.plist restored to placeholder."
  exit 0
fi

if [ -z "${KP_IOS_GOOGLE_CLIENT_ID:-}" ] && [ -f private/ios/build.env ]; then
  # shellcheck disable=SC1091
  . private/ios/build.env
fi
ID="${KP_IOS_GOOGLE_CLIENT_ID:-}"
[ -n "$ID" ] || {
  echo "No iOS client id. Set KP_IOS_GOOGLE_CLIENT_ID, or clone the private overlay" >&2
  echo "into ./private (it carries private/ios/build.env). See docs/SELF-HOSTING.md." >&2
  exit 1
}

grep -q "YOUR_IOS_CLIENT_ID" "$PLIST" || { echo "Info.plist already injected (no placeholder)."; exit 0; }
KP_ID="$ID" perl -pi -e 's/YOUR_IOS_CLIENT_ID/$ENV{KP_ID}/g' "$PLIST"
echo "Injected iOS client id into $PLIST — run '--restore' before committing."
