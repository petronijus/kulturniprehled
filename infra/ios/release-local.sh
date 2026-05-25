#!/usr/bin/env bash
# iOS TestFlight release from the local Mac (MacBook or any Mac with
# the Distribution cert + profile already bootstrapped).
#
# Prerequisites:
#   - Run bootstrap-signing.sh once (imports cert + profile)
#   - Flutter 3.44.0, SPM disabled
#   - 1Password CLI (op-cache)
#
# Usage:
#   infra/ios/release-local.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MOBILE_DIR="$REPO_ROOT/apps/mobile"
APPLE_ID="petronijus@example.com"
API_BASE="https://kulturniprehled.example.com"

info()  { printf '\033[1;34m→ %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

### 1. Pre-flight checks #####################################################
info "Pre-flight checks..."
[[ -d "$MOBILE_DIR/ios" ]] || die "Not in the right repo — $MOBILE_DIR/ios missing"

security find-identity -v -p codesigning | grep -q "Apple Distribution" \
  || die "No Distribution cert in keychain. Run bootstrap-signing.sh first."

flutter --version 2>/dev/null | grep -q "3.44" \
  || echo "  ⚠ Flutter version is not 3.44.x — build may fail"

### 2. Read version ##########################################################
VERSION=$(grep '^version:' "$MOBILE_DIR/pubspec.yaml" | awk '{print $2}')
SEMVER="${VERSION%%+*}"
info "Building version $VERSION (semver: $SEMVER)"

### 3. Build IPA #############################################################
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")

info "Building IPA..."
cd "$MOBILE_DIR"
flutter build ipa --release \
  --export-options-plist=ios/ExportOptions.plist \
  --dart-define=KP_API_BASE="$API_BASE" \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID="$GOOG_CLIENT_ID"
unset GOOG_CLIENT_ID

IPA_FILE="build/ios/ipa/Kulturni Prehled.ipa"
[[ -f "$IPA_FILE" ]] || die "IPA not found"
ok "IPA built"

### 4. Upload to App Store Connect ###########################################
info "Uploading to App Store Connect..."
ALTOOL_PW=$(op-cache "Kulturni prehled Apple ID app-specific password" credential)

xcrun altool --upload-app \
  -f "$IPA_FILE" \
  -t ios \
  -u "$APPLE_ID" \
  -p "$ALTOOL_PW"
unset ALTOOL_PW

ok "Upload complete"
echo ""
ok "iOS v$SEMVER released to TestFlight"
echo "   ASC processes in ~5-15 min, then Družina auto-distributes."
echo "   Smoke test: TestFlight → Kulturní Přehled → Update"
