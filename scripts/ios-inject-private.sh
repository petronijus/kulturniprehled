#!/usr/bin/env bash
# Inject the maintainer-private iOS identifiers into the committed iOS project.
#
# Two values cannot travel through --dart-define and so ship as placeholders:
#
#   YOUR_IOS_CLIENT_ID  apps/mobile/ios/Runner/Info.plist
#                       the iOS Google OAuth client id, static in the plist
#   YOURTEAMID          apps/mobile/ios/ExportOptions.plist
#                       apps/mobile/ios/Runner.xcodeproj/project.pbxproj
#                       the Apple Developer team id, baked into manual signing
#                       (DEVELOPMENT_TEAM, DevelopmentTeam and the
#                       "Apple Distribution: … (TEAM)" identity)
#
# This swaps both for real values before an iOS build; `--restore` puts the
# placeholders back so they stay that way in git.
#
# Source of each value (first match wins):
#   1. $KP_IOS_GOOGLE_CLIENT_ID / $KP_IOS_TEAM_ID in the environment
#   2. private/ios/build.env from the private overlay (maintainer convenience)
# Self-hosters: export both — see docs/SELF-HOSTING.md.
#
# Usage:
#   scripts/ios-inject-private.sh            # placeholders -> real values
#   scripts/ios-inject-private.sh --restore  # real values -> placeholders
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="apps/mobile/ios/Runner/Info.plist"
EXPORT_OPTS="apps/mobile/ios/ExportOptions.plist"
PBXPROJ="apps/mobile/ios/Runner.xcodeproj/project.pbxproj"

if [ "${1:-}" = "--restore" ]; then
  git checkout -- "$PLIST" "$EXPORT_OPTS" "$PBXPROJ"
  echo "iOS project restored to placeholders."
  exit 0
fi

if { [ -z "${KP_IOS_GOOGLE_CLIENT_ID:-}" ] || [ -z "${KP_IOS_TEAM_ID:-}" ]; } \
   && [ -f private/ios/build.env ]; then
  # shellcheck disable=SC1091
  . private/ios/build.env
fi

missing=""
[ -n "${KP_IOS_GOOGLE_CLIENT_ID:-}" ] || missing="$missing KP_IOS_GOOGLE_CLIENT_ID"
[ -n "${KP_IOS_TEAM_ID:-}" ]          || missing="$missing KP_IOS_TEAM_ID"
if [ -n "$missing" ]; then
  echo "Missing:$missing. Set them in the environment, or clone the private" >&2
  echo "overlay into ./private (it carries private/ios/build.env)." >&2
  echo "See docs/SELF-HOSTING.md." >&2
  exit 1
fi

inject() {  # placeholder real_value file...
  local placeholder="$1" value="$2"; shift 2
  local file touched=0
  for file in "$@"; do
    grep -q "$placeholder" "$file" || continue
    KP_VALUE="$value" KP_PLACEHOLDER="$placeholder" \
      perl -pi -e 's/\Q$ENV{KP_PLACEHOLDER}\E/$ENV{KP_VALUE}/g' "$file"
    echo "  $file"
    touched=1
  done
  [ "$touched" = 1 ] || echo "  ($placeholder already injected)"
}

echo "Injecting iOS Google client id:"
inject YOUR_IOS_CLIENT_ID "$KP_IOS_GOOGLE_CLIENT_ID" "$PLIST"
echo "Injecting Apple team id:"
inject YOURTEAMID "$KP_IOS_TEAM_ID" "$EXPORT_OPTS" "$PBXPROJ"
echo "Run '--restore' before committing."
