---
name: ios-release-macbook
description: Build and release Kulturní Přehled iOS to TestFlight directly on the MacBook. Requires one-time signing bootstrap (Distribution cert + provisioning profile). No VM needed.
---

## Task

Build the iOS IPA locally on the MacBook and upload to App Store Connect
for TestFlight distribution.

## One-time bootstrap (signing setup)

Before the first build on a new Mac, the Distribution certificate and
provisioning profile must be imported. Check if they're already present:

```bash
security find-identity -v -p codesigning | grep "Apple Distribution"
```

If the cert is missing, run the bootstrap:

### Bootstrap step 1: Import the .p12

The Distribution cert + private key are stored in 1Password as
`KP iOS Distribution .p12` (password field: `password`).

```bash
# Download .p12 from 1Password
op document get "KP iOS Distribution .p12" --vault Personal \
  --output /tmp/dist-export.p12
P12_PW=$(op-cache "KP iOS Distribution .p12" password)

# Import into login keychain
security import /tmp/dist-export.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P "$P12_PW" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild -A

rm /tmp/dist-export.p12
unset P12_PW
```

Then set the partition list so codesign doesn't prompt. This requires the
user's login keychain password — **ask the user** to enter it when
prompted, or have them run the command manually:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "LOGIN_KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db
```

### Bootstrap step 2: Install provisioning profile

The profile is available from the macOS VM or from App Store Connect.
Easiest path — download from VM (if running):

```bash
scp petronijus@192.0.2.154:~/Library/MobileDevice/Provisioning\ Profiles/f2ec53a5-77da-4bec-b73b-6d124438e666.mobileprovision \
  ~/Library/MobileDevice/Provisioning\ Profiles/
```

If the VM is not running, download from ASC API:

```bash
ASC_KEY_ID=$(op-cache "Kulturni prehled ASC API Key" "key_id")
ASC_ISSUER=$(op-cache "Kulturni prehled ASC API Key" "issuer_id")
# Use xcrun altool or the ASC API to fetch profile MY69457XDZ
```

### Bootstrap step 3: Verify Flutter + SPM

```bash
flutter --version  # Must be 3.44.0
flutter config --no-enable-swift-package-manager  # One-time per machine
```

### Bootstrap step 4: Verify

```bash
security find-identity -v -p codesigning | grep "Apple Distribution"
ls ~/Library/MobileDevice/Provisioning\ Profiles/f2ec53a5-*.mobileprovision
```

Both must succeed. Bootstrap is done — never needs repeating on this Mac
unless the cert expires or the keychain is reset.

---

## Per-release build

### 1. Pre-flight

Confirm the version in `apps/mobile/pubspec.yaml` is bumped and pushed
to `origin/main`. If not, bump it now and push.

```bash
cd ~/Documents/Dev/kulturniprehled  # or wherever the repo lives
git checkout main && git pull --ff-only
grep ^version: apps/mobile/pubspec.yaml
```

### 2. Build IPA

```bash
cd apps/mobile
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")

flutter build ipa --release \
  --export-options-plist=ios/ExportOptions.plist \
  --dart-define=KP_API_BASE=https://kulturniprehled.example.com \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID="$GOOG_CLIENT_ID"

unset GOOG_CLIENT_ID
```

Expect `✓ Built IPA to build/ios/ipa`. Takes 3-5 minutes.

### 3. Upload to App Store Connect

```bash
ALTOOL_PW=$(op-cache "Kulturni prehled Apple ID app-specific password" credential)

xcrun altool --upload-app \
  -f "build/ios/ipa/Kulturni Prehled.ipa" \
  -t ios \
  -u petronijus@example.com \
  -p "$ALTOOL_PW"

unset ALTOOL_PW
```

Expect `UPLOAD SUCCEEDED`. ASC processes in ~5-15 min, then Družina
auto-distributes to TestFlight.

### 4. Report

Tell the user (in Czech):
- Version uploaded
- That Běla gets it automatically via TestFlight Družina group
- Smoke test reminder: TestFlight → Kulturní Přehled → Update

## Reference

- Signing: manual, `Apple Distribution: Petr Parkan Janda (YOURTEAMID)`,
  profile `KP Distribution` (UUID `f2ec53a5-77da-4bec-b73b-6d124438e666`)
- 1Password items:
  - `KP iOS Distribution .p12` — cert + key bundle (vault: Personal)
  - `Kulturni prehled Apple ID app-specific password` → `credential`
  - `Kulturni prehled google Web OAuth client` → `client ID`
- Shell script version: `infra/ios/release-local.sh`
