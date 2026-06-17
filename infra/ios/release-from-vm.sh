#!/usr/bin/env bash
# iOS TestFlight release via the Proxmox macOS VM (server-mac).
#
# Run from ANY machine with SSH access to the Proxmox host + macOS VM
# and 1Password CLI (op-cache). The script:
#   1. Ensures Windows VM is down and macOS VM is up
#   2. Pulls latest main on the VM
#   3. Builds a signed IPA (manual Distribution signing)
#   4. Uploads to App Store Connect via xcrun notarytool / altool
#   5. Optionally shuts down the macOS VM and restarts Windows
#
# Usage:
#   infra/ios/release-from-vm.sh            # interactive — prompts before VM swap
#   infra/ios/release-from-vm.sh --no-swap  # skip VM power management (VM already up)

set -euo pipefail

### Configuration ############################################################
PVE_HOST="root@192.0.2.100"
MAC_VM_ID=108
WIN_VM_ID=106
MAC_HOST="petronijus@192.0.2.154"
REPO_DIR="~/Documents/Dev/kulturniprehled"
APPLE_ID="petronijus@example.com"
BUNDLE_ID="com.kulturniprehled.kpMobile"
API_BASE="https://kulturniprehled.example.com"
NO_SWAP="${1:-}"
##############################################################################

info()  { printf '\033[1;34m→ %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

### 0. VM power management ###################################################
if [[ "$NO_SWAP" != "--no-swap" ]]; then
  info "Checking VM states..."
  WIN_STATUS=$(ssh "$PVE_HOST" "qm status $WIN_VM_ID" 2>/dev/null | awk '{print $2}')
  MAC_STATUS=$(ssh "$PVE_HOST" "qm status $MAC_VM_ID" 2>/dev/null | awk '{print $2}')

  if [[ "$MAC_STATUS" == "running" ]]; then
    ok "macOS VM already running"
  else
    if [[ "$WIN_STATUS" == "running" ]]; then
      info "Shutting down Windows VM (graceful, via guest agent)..."
      ssh "$PVE_HOST" "qm shutdown $WIN_VM_ID --timeout 120"
      info "Waiting for Windows VM to stop..."
      until [[ "$(ssh "$PVE_HOST" "qm status $WIN_VM_ID" | awk '{print $2}')" == "stopped" ]]; do
        sleep 5
      done
      ok "Windows VM stopped"
    fi
    info "Starting macOS VM..."
    ssh "$PVE_HOST" "qm start $MAC_VM_ID" 2>&1 | grep -v "^kvm: warning" || true
    info "Waiting for SSH..."
    until ssh -o ConnectTimeout=5 -o BatchMode=yes "$MAC_HOST" 'true' 2>/dev/null; do
      sleep 10
    done
    ok "macOS VM SSH ready"
  fi
fi

### 1. Verify SSH ############################################################
info "Verifying macOS VM..."
ssh "$MAC_HOST" 'bash -lc "sw_vers --productVersion && flutter --version --machine 2>/dev/null | head -1"' \
  || die "Cannot reach macOS VM via SSH"
ok "macOS VM reachable"

### 2. Pull latest code ######################################################
info "Pulling latest main on VM..."
ssh "$MAC_HOST" "bash -lc 'cd $REPO_DIR && git checkout main && git pull --ff-only'"
ok "Code up to date"

### 3. Read version from pubspec #############################################
VERSION=$(ssh "$MAC_HOST" "bash -lc 'grep ^version: $REPO_DIR/apps/mobile/pubspec.yaml'" | awk '{print $2}')
SEMVER="${VERSION%%+*}"
info "Building version $VERSION (semver: $SEMVER)"

### 4. Unlock keychain #######################################################
info "Unlocking login keychain on VM..."
MAC_PW=$(op-cache "sudo server-mac" password)
ssh "$MAC_HOST" "security unlock-keychain -p '$MAC_PW' ~/Library/Keychains/login.keychain-db && \
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '$MAC_PW' ~/Library/Keychains/login.keychain-db >/dev/null 2>&1"
ok "Keychain unlocked"

### 5. Build IPA #############################################################
# codesign via SSH fails with errSecInternalComponent on macOS 26 VMs —
# the SSH session lacks the GUI security context. We write a build script
# and launch it via osascript so it runs in the Aqua/loginwindow session.
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")

info "Building IPA via GUI session (this takes 3-5 minutes)..."
ssh "$MAC_HOST" "cat > /tmp/kp_ios_build.sh << 'BUILDSCRIPT'
#!/bin/bash
export PATH=\"/usr/local/share/flutter/bin:/usr/local/bin:\$PATH\"
export HOME=/Users/petronijus
security unlock-keychain -p \"$MAC_PW\" ~/Library/Keychains/login.keychain-db
cd $REPO_DIR && ./scripts/ios-inject-client-id.sh
cd $REPO_DIR/apps/mobile
flutter build ipa --release \
  --export-options-plist=ios/ExportOptions.plist \
  --dart-define=KP_API_BASE=$API_BASE \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID=$GOOG_CLIENT_ID \
  > /tmp/kp_ios_build.log 2>&1
echo \"\$?\" > /tmp/kp_ios_build_exit
cd $REPO_DIR && ./scripts/ios-inject-client-id.sh --restore
BUILDSCRIPT
chmod +x /tmp/kp_ios_build.sh"

ssh "$MAC_HOST" "rm -f /tmp/kp_ios_build_exit && osascript -e 'do shell script \"/tmp/kp_ios_build.sh &\"'"
unset MAC_PW GOOG_CLIENT_ID

# Wait for the build to finish
info "Waiting for build..."
until ssh "$MAC_HOST" "test -f /tmp/kp_ios_build_exit" 2>/dev/null; do
  sleep 15
done

BUILD_EXIT=$(ssh "$MAC_HOST" "cat /tmp/kp_ios_build_exit")
if [[ "$BUILD_EXIT" != "0" ]]; then
  ssh "$MAC_HOST" "tail -30 /tmp/kp_ios_build.log" >&2
  die "IPA build failed (exit $BUILD_EXIT) — see log above"
fi

IPA_PATH="$REPO_DIR/apps/mobile/build/ios/ipa/Kulturni Prehled.ipa"
ssh "$MAC_HOST" "test -f '$IPA_PATH'" || die "IPA not found at expected path"
ok "IPA built"

### 6. Upload to App Store Connect ###########################################
info "Uploading to App Store Connect..."
ALTOOL_PW=$(op-cache "Kulturni prehled Apple ID app-specific password" credential)

ssh "$MAC_HOST" "bash -lc '
  xcrun altool --upload-app \
    -f \"$IPA_PATH\" \
    -t ios \
    -u $APPLE_ID \
    -p \"$ALTOOL_PW\"
'"
unset ALTOOL_PW
ok "Upload complete — ASC will process in ~5-15 min, then Družina auto-distributes to TestFlight"

### 7. Swap VMs back (optional) ##############################################
if [[ "$NO_SWAP" != "--no-swap" ]]; then
  read -rp "Shut down macOS VM and start Windows? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    info "Shutting down macOS VM..."
    ssh "$MAC_HOST" 'sudo shutdown -h now' 2>/dev/null || true
    sleep 10
    until [[ "$(ssh "$PVE_HOST" "qm status $MAC_VM_ID" | awk '{print $2}')" == "stopped" ]]; do
      sleep 5
    done
    info "Starting Windows VM..."
    ssh "$PVE_HOST" "qm start $WIN_VM_ID"
    ok "Windows VM starting"
  fi
fi

echo ""
ok "iOS v$SEMVER released to TestFlight"
echo "   Běla gets it automatically via Družina internal testing group."
echo "   Smoke test: TestFlight → Kulturní Přehled → Update"
