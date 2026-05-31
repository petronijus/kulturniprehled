---
name: ios-release-vm
description: Build and release Kulturní Přehled iOS to TestFlight via the Proxmox macOS VM (server-mac). Handles VM power management, code signing, IPA build, and App Store Connect upload. Run from any machine with SSH + 1Password CLI.
---

## Task

Build the iOS IPA on the Proxmox macOS VM and upload to App Store Connect
for TestFlight distribution. The Družina internal testing group auto-
distributes to Běla — no manual App Store Connect clicks needed.

**Important:** The macOS VM and Windows VM share RAM — only one can run
at a time. Always shut down Windows gracefully (guest agent) before
starting macOS.

### 0. Pre-flight

Confirm the version in `apps/mobile/pubspec.yaml` is bumped and pushed
to `origin/main`. If not, bump it now (increment the `+N` build number
at minimum) and push.

### 1. VM power management

```bash
# Check VM states
ssh root@192.0.2.100 'qm status 106; qm status 108'
```

- If macOS VM (108) is already running → skip to step 2.
- If Windows VM (106) is running → shut it down **gracefully** (never
  force-stop unless user explicitly confirms):

```bash
ssh root@192.0.2.100 'qm shutdown 106 --timeout 120'
# Wait for it to stop:
# ssh root@192.0.2.100 'qm status 106'  → status: stopped
```

- Start macOS VM:

```bash
ssh root@192.0.2.100 'qm start 108'
# Ignore kvm CPU feature warnings — normal for Hackintosh VM.
# VM boots with OpenCore 1.0.7, 5s timeout, auto-login.
# Wait ~90-120s for SSH:
# ssh petronijus@192.0.2.154 'echo ok'
```

### 2. Pull latest code on VM

```bash
ssh petronijus@192.0.2.154 'bash -lc "
  cd ~/Documents/Dev/kulturniprehled && \
  git checkout main && git pull --ff-only && \
  grep ^version: apps/mobile/pubspec.yaml
"'
```

If there are local changes blocking pull, stash them:
`git stash && git pull --ff-only`.

### 3. Unlock keychain

```bash
MAC_PW=$(op-cache "sudo server-mac" password)
ssh petronijus@192.0.2.154 "
  security unlock-keychain -p '$MAC_PW' ~/Library/Keychains/login.keychain-db && \
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k '$MAC_PW' ~/Library/Keychains/login.keychain-db >/dev/null 2>&1
"
```

### 4. Build IPA (via GUI session)

**Critical:** `codesign` from SSH fails with `errSecInternalComponent` on
macOS 26 VMs. The build MUST run in the GUI/Aqua session via `osascript`.

```bash
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")
```

Write a build script to the VM and launch it via osascript:

```bash
ssh petronijus@192.0.2.154 "cat > /tmp/kp_ios_build.sh << 'SCRIPT'
#!/bin/bash
export PATH=\"/usr/local/share/flutter/bin:/usr/local/bin:\$PATH\"
export HOME=/Users/petronijus
security unlock-keychain -p \"$MAC_PW\" ~/Library/Keychains/login.keychain-db
cd ~/Documents/Dev/kulturniprehled/apps/mobile
flutter build ipa --release \
  --export-options-plist=ios/ExportOptions.plist \
  --dart-define=KP_API_BASE=https://kulturniprehled.example.com \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID=$GOOG_CLIENT_ID \
  > /tmp/kp_ios_build.log 2>&1
echo \"\$?\" > /tmp/kp_ios_build_exit
SCRIPT
chmod +x /tmp/kp_ios_build.sh"

ssh petronijus@192.0.2.154 "rm -f /tmp/kp_ios_build_exit && \
  osascript -e 'do shell script \"/tmp/kp_ios_build.sh &\"'"
```

Poll for completion (takes 3-5 minutes):

```bash
# Check: ssh petronijus@192.0.2.154 'cat /tmp/kp_ios_build_exit 2>/dev/null'
# When file exists: 0 = success, anything else = failure
# On failure: ssh petronijus@192.0.2.154 'tail -30 /tmp/kp_ios_build.log'
```

Unset secrets after build: `unset MAC_PW GOOG_CLIENT_ID`.

### 5. Upload to App Store Connect

```bash
ALTOOL_PW=$(op-cache "Kulturni prehled Apple ID app-specific password" credential)

ssh petronijus@192.0.2.154 "bash -lc '
  cd ~/Documents/Dev/kulturniprehled/apps/mobile && \
  xcrun altool --upload-app \
    -f \"build/ios/ipa/Kulturni Prehled.ipa\" \
    -t ios \
    -u petronijus@example.com \
    -p \"$ALTOOL_PW\"
'"
unset ALTOOL_PW
```

Expect `UPLOAD SUCCEEDED`. ASC processes the build in ~5-15 min, then
Družina auto-distributes to TestFlight.

### 6. VM swap back (ask user)

Ask the user if they want to shut down macOS VM and start Windows back.
If yes:

```bash
ssh petronijus@192.0.2.154 'sudo shutdown -h now' 2>/dev/null || true
# Wait for status: stopped
ssh root@192.0.2.100 'qm start 106'
```

### 7. Report

Tell the user (in Czech):
- Version uploaded
- That Běla gets it automatically via TestFlight Družina group
- Smoke test reminder: TestFlight → Kulturní Přehled → Update

## Reference

- VM: `192.0.2.154` (macOS 26.5, OpenCore 1.0.7, Flutter 3.44.0)
- Proxmox: `root@192.0.2.100` (VM 108 = macOS, VM 106 = Windows)
- Signing: manual, `Apple Distribution: Petr Parkan Janda (YOURTEAMID)`,
  profile `KP Distribution`
- Shell script version: `infra/ios/release-from-vm.sh`
