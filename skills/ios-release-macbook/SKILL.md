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

Current Xcode keeps profiles in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`; older Xcode
used `~/Library/MobileDevice/Provisioning Profiles/`. Check the new
directory first: on a Mac that already has the profile (downloaded by
Xcode), a check of the old directory alone misses it and sends you into a
needless bootstrap. `infra/ios/bootstrap-signing.sh` still copies into the
old directory, which Xcode reads as well.

```bash
ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/f2ec53a5-*.mobileprovision \
  ~/Library/MobileDevice/Provisioning\ Profiles/f2ec53a5-*.mobileprovision 2>/dev/null
```

If neither has it, copy it from the macOS VM (if running):

```bash
mkdir -p ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
scp "petronijus@192.0.2.154:~/Library/MobileDevice/Provisioning Profiles/f2ec53a5-77da-4bec-b73b-6d124438e666.mobileprovision" \
  ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
```

Otherwise download profile `KP Distribution` from the Apple Developer
portal (Certificates, Identifiers & Profiles → Profiles) and open it, or
let Xcode fetch it (Settings → Accounts → Download Manual Profiles).

### Bootstrap step 3: App Store Connect API key

`infra/ios/release-local.sh` uploads with the App Store Connect API key,
not an Apple ID. It reads `key_id` and `issuer_id` from the 1Password item
`Kulturni prehled ASC API Key` and expects the key file at
`~/.appstoreconnect/private_keys/AuthKey_<key_id>.p8`. Save the item's
private key there once (mode `600`); never print it.

### Bootstrap step 4: Release config

The script takes `KP_API_BASE` from the environment or from
`private/config/mobile-release.conf` in the private overlay (the same file
`just build-aab` reads). Clone the overlay into `private/` once; the script
refuses a host that is not `https://` or still the `example.com`
placeholder.

### Bootstrap step 5: Verify Flutter + SPM

```bash
flutter --version  # Must be 3.47.5
flutter config --no-enable-swift-package-manager  # One-time per machine
```

### Bootstrap step 6: Verify

```bash
security find-identity -v -p codesigning | grep "Apple Distribution"
ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/f2ec53a5-*.mobileprovision \
  ~/Library/MobileDevice/Provisioning\ Profiles/f2ec53a5-*.mobileprovision 2>/dev/null
ls ~/.appstoreconnect/private_keys/AuthKey_*.p8
test -f private/config/mobile-release.conf
```

The cert, one profile, the key file and the config must all be there.
Bootstrap is done — never needs repeating on this Mac
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

### 2. Build and upload

```bash
infra/ios/release-local.sh
```

Run it from the repo root; never rebuild the `flutter build ipa` /
`altool` commands by hand. The script checks the cert and the release
config, injects the private iOS values (and restores the placeholders on
exit), builds the IPA with the real `KP_API_BASE` and the OAuth client
ID, and uploads it with the App Store Connect API key. Hand-typed
commands with the public placeholder host would ship an app that talks to
a server that does not exist.

Expect `UPLOAD SUCCEEDED` after 3-5 minutes of build. ASC processes in
~5-15 min, then Družina auto-distributes to TestFlight.

### 3. Report

Tell the user (in Czech):
- Version uploaded
- That Běla gets it automatically via TestFlight Družina group
- Smoke test reminder: TestFlight → Kulturní Přehled → Update

## Reference

- Signing: manual, `Apple Distribution: Petr Parkan Janda (YOURTEAMID)`,
  profile `KP Distribution` (UUID `f2ec53a5-77da-4bec-b73b-6d124438e666`)
- 1Password items:
  - `KP iOS Distribution .p12` — cert + key bundle (vault: Personal)
  - `Kulturni prehled ASC API Key` → `key_id`, `issuer_id`, the `.p8`
    private key
  - `Kulturni prehled google Web OAuth client` → `client ID`
- Release script: `infra/ios/release-local.sh`; signing bootstrap:
  `infra/ios/bootstrap-signing.sh`
