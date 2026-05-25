#!/usr/bin/env bash
# One-time signing bootstrap for a new Mac build machine.
#
# Exports the Distribution cert + private key from the Proxmox macOS VM
# (where they were originally created) and imports them into the local
# keychain. Also copies the provisioning profile.
#
# Prerequisites:
#   - SSH access to the macOS VM (192.0.2.154)
#   - 1Password CLI (op-cache) for the VM password
#   - The macOS VM must be running
#
# After running this, the machine can build IPAs via:
#   infra/ios/release-local.sh
#
# Usage:
#   infra/ios/bootstrap-signing.sh

set -euo pipefail

MAC_HOST="petronijus@192.0.2.154"
PROFILE_UUID="f2ec53a5-77da-4bec-b73b-6d124438e666"
P12_PASS="kp-transfer-$(date +%s)"

info()  { printf '\033[1;34m→ %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

### 1. Export .p12 from VM ###################################################
info "Exporting Distribution cert + key from VM as .p12..."
MAC_PW=$(op-cache "sudo server-mac" password)

ssh "$MAC_HOST" "bash -lc '
  security unlock-keychain -p \"$MAC_PW\" ~/Library/Keychains/login.keychain-db

  # Export cert from keychain
  security find-certificate -c \"Apple Distribution: Petr Parkan Janda\" -p \
    ~/Library/Keychains/login.keychain-db > /tmp/dist-cert.pem

  # Combine with private key into .p12 (-legacy required for macOS import)
  openssl pkcs12 -export -legacy \
    -inkey ~/signing/dist.key \
    -in /tmp/dist-cert.pem \
    -out /tmp/dist-export.p12 \
    -passout pass:$P12_PASS

  rm /tmp/dist-cert.pem
  echo ok
'"

scp "$MAC_HOST:/tmp/dist-export.p12" /tmp/dist-export.p12
ssh "$MAC_HOST" "rm /tmp/dist-export.p12"
ok "Downloaded .p12"

### 2. Import .p12 into local keychain ######################################
info "Importing Distribution cert into local keychain..."
security import /tmp/dist-export.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild -A

rm /tmp/dist-export.p12
ok "Distribution cert imported"

# Allow codesign access without GUI prompt
info "Setting key partition list..."
read -rsp "Enter your Mac login keychain password: " LOCAL_KC_PW
echo
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$LOCAL_KC_PW" ~/Library/Keychains/login.keychain-db
unset LOCAL_KC_PW
ok "Partition list updated"

### 3. Copy provisioning profile #############################################
info "Copying provisioning profile from VM..."
PROFILE_DIR=~/Library/MobileDevice/Provisioning\ Profiles
mkdir -p "$PROFILE_DIR"
scp "$MAC_HOST:~/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision" \
  "$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
ok "Profile installed"

### 4. Verify ################################################################
info "Verifying signing identity..."
security find-identity -v -p codesigning | grep "Apple Distribution" \
  || die "Distribution cert not found in keychain"
ok "Ready — this machine can now build signed IPAs"

echo ""
echo "Next steps:"
echo "  1. Ensure Flutter 3.44.0 is installed"
echo "  2. Run: flutter config --no-enable-swift-package-manager"
echo "  3. Build: infra/ios/release-local.sh"

unset MAC_PW P12_PASS
