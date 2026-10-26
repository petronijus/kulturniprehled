#!/usr/bin/env bash
# iOS TestFlight release from the local Mac (MacBook or any Mac with
# the Distribution cert + profile already bootstrapped).
#
# Prerequisites:
#   - Run bootstrap-signing.sh once (imports cert + profile)
#   - Flutter 3.47.5, SPM disabled
#   - 1Password CLI (op-cache)
#
# Usage:
#   infra/ios/release-local.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MOBILE_DIR="$REPO_ROOT/apps/mobile"

info()  { printf '\033[1;34m→ %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

### 1. Pre-flight checks #####################################################
info "Pre-flight checks..."
[[ -d "$MOBILE_DIR/ios" ]] || die "Not in the right repo — $MOBILE_DIR/ios missing"

security find-identity -v -p codesigning | grep -q "Apple Distribution" \
  || die "No Distribution cert in keychain. Run bootstrap-signing.sh first."

flutter --version 2>/dev/null | grep -q "Flutter 3.47.5 " \
  || echo "  ⚠ Flutter version is not 3.47.5 — build may fail"

# The real API host stays out of this public repo: the environment or the
# private overlay supplies it, as for `just build-aab`. This script used to
# carry the public placeholder host, which would have shipped an app that
# talks to a server that does not exist.
if [[ -z "${KP_API_BASE:-}" ]]; then
  conf="$REPO_ROOT/private/config/mobile-release.conf"
  [[ -f "$conf" ]] || die "Set KP_API_BASE or clone the private overlay ($conf is missing)"
  # shellcheck source=/dev/null
  source "$conf"
fi
[[ "$KP_API_BASE" == https://* && "$KP_API_BASE" != *example.com* ]] \
  || die "KP_API_BASE is not a real https host: $KP_API_BASE"

# Upload with the App Store Connect API key (no Apple ID, no app-specific
# password); altool finds the .p8 in ~/.appstoreconnect/private_keys/.
ASC_KEY_ID=$(op-cache "Kulturni prehled ASC API Key" key_id)
ASC_ISSUER=$(op-cache "Kulturni prehled ASC API Key" issuer_id)
[[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" ]] \
  || die "ASC key AuthKey_${ASC_KEY_ID}.p8 missing — save the 1Password item's private_key to ~/.appstoreconnect/private_keys/"

### 2. Read version ##########################################################
VERSION=$(grep '^version:' "$MOBILE_DIR/pubspec.yaml" | awk '{print $2}')
SEMVER="${VERSION%%+*}"
info "Building version $VERSION (semver: $SEMVER)"

### 3. Build IPA #############################################################
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")

# Inject the real iOS OAuth client id (Info.plist ships a placeholder); restore
# it on exit so the placeholder stays in git.
"$REPO_ROOT/scripts/ios-inject-private.sh"
trap '"$REPO_ROOT/scripts/ios-inject-private.sh" --restore >/dev/null 2>&1 || true' EXIT

info "Building IPA..."
cd "$MOBILE_DIR"
flutter build ipa --release \
  --export-options-plist=ios/ExportOptions.plist \
  --dart-define=KP_API_BASE="$KP_API_BASE" \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID="$GOOG_CLIENT_ID"
unset GOOG_CLIENT_ID

IPA_FILE="build/ios/ipa/Kulturni Prehled.ipa"
[[ -f "$IPA_FILE" ]] || die "IPA not found"
ok "IPA built"

### 4. Upload to App Store Connect ###########################################
info "Uploading to App Store Connect..."
xcrun altool --upload-app \
  -f "$IPA_FILE" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER"

ok "Upload complete"
echo ""
ok "iOS v$SEMVER released to TestFlight"
echo "   ASC processes in ~5-15 min, then Družina auto-distributes."
echo "   Smoke test: TestFlight → Kulturní Přehled → Update"
