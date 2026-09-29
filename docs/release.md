# Release

How a mobile release ships: the Android bundle to Google Play's internal
testing track, the backend image when the API changed, the iOS build on
TestFlight, and the free-Apple-ID sideload for a physical iPhone. Real
hostnames, IDs and credentials live in the private overlay (`private/`); this
public file uses placeholders. Every step runs locally — there is no hosted CI.

## Android (Google Play internal testing)

Android ships through the Play Console **internal testing** track, as Pinkni
does: no review, Play delivers updates, and the path to production is the
same upload. Until 1.2.0 it was a sideloaded APK on GitHub Releases.

### One-time setup (2026-09-29)

- **Play Console** (developer account `Bastla`, the one Pinkni uses): app
  `Kulturní Přehled`, package `com.kulturniprehled.kp_mobile`, **Play App
  Signing with a Google-generated app signing key**, internal testing track
  with the developer-account tester list `Internal testers`.
- **Upload key**: 1Password `Kulturni Prehled Android upload key` (vault
  Personal: the `.jks` as the file `keystore file`, plus `store password`,
  `key password`, `key alias`). PKCS12, RSA 4096, alias `upload`,
  `CN=Kulturni Prehled upload, O=Bastla, C=CZ`. If it is lost or leaked,
  request an upload key reset in Play Console; the app signing key stays
  with Google.
- **Google Sign-In**: Google Cloud (project `petr-apps`, Google Auth Platform
  → Clients) needs an Android OAuth client for every **app signing**
  certificate, not for the upload key. Play signs KP with quantum-ready
  hybrid signing, so there are three: `deployment`, `hybrid classical` and
  `hybrid PQC` (Play Console → Protected with Play → Play Store distribution
  → Play app signing → download the certificates; `keytool -printcert -file`
  gives each SHA-1). They are the clients `KP Mobile (Play, deployment)`,
  `KP Mobile (Play, hybrid classical)` and `KP Mobile (Play, hybrid PQC)`;
  `KP Mobile (debug)` stays for debug builds. A missing SHA-1 shows up as a
  sign-in that fails right after the account is picked.
- **Moving a phone from the old APK**: the sideloaded APK was signed with the
  retired `kp-release.keystore`, so Play cannot update it in place. Uninstall
  it once, then install from the testers' opt-in link. Everything that
  matters is on the server; the phone re-syncs after sign-in.

### Per release

1. **Version**: `apps/mobile/pubspec.yaml` → `version: X.Y.Z+N`. `N` is the
   Android version code; Play refuses a code it has seen, so it only goes up.
   The `/repo-release` skill bumps it together with the CHANGELOG and the tag.
2. **Gate**: `just ci` green on the Linux desktop or the MacBook
   ([development.md](./development.md#checks)).
3. **Bundle**: `just build-aab`. It reads the upload key and the OAuth client
   ID from 1Password into a temporary directory for this one build, takes
   `KP_API_BASE` from the environment or `private/config/mobile-release.conf`,
   builds `apps/mobile/build/app/outputs/bundle/release/app-release.aab` and
   checks that the upload key signed it. A plain `flutter build appbundle`
   without the key fails on purpose, so a debug-signed bundle never reaches
   Play.
4. **Upload**: Play Console → Kulturní Přehled → Test and release → Testing →
   Internal testing → Create new release → upload the `.aab` → release notes
   → Save → Review release → Start rollout. Testers get the update from the
   Play Store within minutes.
5. **GitHub Release**: the tag's release carries the notes only; the bundle
   goes to Play, not to GitHub.

### Backend deploy (only when the API or the planner changed)

The image is built **locally** and pushed to GHCR; the VM only pulls
(`scripts/build-push.sh`, then `upgrade.sh` — never `--build` on the VM;
see ai-config `docs/DEPLOY-STANDARD.md`).

```bash
KP_API_TAG=$(git rev-parse --short HEAD) ./scripts/build-push.sh
ssh petronijus@192.0.2.101 'cd /opt/kp \
  && sed -i "s/^KP_API_TAG=.*/KP_API_TAG=<tag>/" .env \
  && KP_API_TAG=<tag> ./infra/deploy/upgrade.sh'
```

`KP_API_TAG` stays pinned in `/opt/kp/.env` (infra/deploy/README.md): any
later `docker compose up` re-creates the API from that tag, so the pin moves
with every deploy. The VM checkout pulls over HTTPS (the repo is public) so
the compose files follow `main`. If a release changes
`infra/deploy/upgrade.sh`, run it twice — the first run pulls the new
script, the second uses it.

### Smoke test

- `curl https://kulturniprehled.example.com/healthz` → `200 {"status":"ok",…}`
- On the Pixel, update from Play, sign in; agenda, detail, month view,
  watchlist and stats render the way the release notes describe; a
  reminder fires on a locked phone.

## iOS dev sideload (physical device, free Apple ID)

Pre-Apple-Developer-Program flow for installing release builds on a
physical iPhone — works with the free Apple ID tier. App expires after
**7 days** and needs reinstalling. No TestFlight, no App Store, just
USB + signing certs Xcode mints on the fly.

### One-time setup per device

1. **Pair** — plug iPhone in USB-C, unlock, tap "Trust This Computer".
   First time only, also pair in **Xcode → Window → Devices and
   Simulators** (the device shows up as "unpaired" in
   `flutter devices` until you confirm pairing there).
2. **Developer Mode** — only appears in iOS Settings *after* the device
   has been paired with a Mac running Xcode or `flutter devices`. Then:
   Settings → Privacy & Security → Developer Mode → ON → restart →
   confirm.
3. **Xcode signing** — open `apps/mobile/ios/Runner.xcworkspace`,
   select the Runner target → Signing & Capabilities → tick
   "Automatically manage signing" → pick your Apple ID team from the
   dropdown. For Petr's personal Apple ID the Team ID is
   **`YOURTEAMID`** (already pinned in `project.pbxproj`; no re-pick
   needed unless the file is reset).

### Run on device

```bash
cd apps/mobile
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")
flutter run --release -d <device-id> \
  --dart-define=KP_API_BASE=https://kulturniprehled.example.com \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID="$GOOG_CLIENT_ID"
unset GOOG_CLIENT_ID
```

Find `<device-id>` via `flutter devices`. Běla's iPhone is
`00000000-0000000000000000`.

`--release` matters: a release-mode app keeps running after you Ctrl-C
the `flutter run` console and after the USB cable is removed. Debug
builds need the daemon connection to stay alive.

### First-launch gotcha

The first install on a fresh Apple ID typically fails with
`Could not run … on <udid>` — the device hasn't yet trusted the
developer certificate Xcode minted. On the iPhone:

- Settings → General → VPN & Device Management → Developer App → tap
  your Apple ID → **Trust**

…then re-run `flutter run`. Subsequent installs skip the trust step.

### Cert expiry

Free Apple ID provisioning profiles last **7 days**. After that the
app refuses to launch ("Untrusted Developer" / "Could not verify
app"). Fix: `flutter run --release` again — Xcode mints a fresh 7-day
cert each time. For longer-lived installs (TestFlight, no re-sign),
see the next section.

## iOS release (TestFlight)

iOS distribution needs a Mac because Xcode + CocoaPods can't run on
Linux. Two paths now exist:

- **Local Mac (MacBook).** Original recipe — kept here for the case
  when you're sitting at the MacBook and just want to ship. Petr's
  MacBook should be on Flutter 3.47.5 (the `assets-source/brand`
  contract, the `import 'package:flutter/cupertino.dart'` change to
  `theme.dart`, and the manual-signing pbxproj edits all depend on
  3.44+; see `private/docs/handover.md`, 2026-05-22 entry,
  for the MacBook upgrade steps).
- **Headless via Proxmox MacOS VM (`server-mac`, `192.0.2.154`).**
  Documented end-to-end in `private/docs/handover.md`
  under the 2026-05-22 session, and in the `ios-release-vm` skill — drives the build over SSH from any
  workstation, authed by the App Store Connect API key in 1Password.
  No GUI clicks. Preferred for routine releases.

The section below is the **local Mac** recipe.

### One-time setup (done 2026-05-18 — do NOT redo unless rebuilding the account)

1. **App Store Connect record** — `Kulturní Přehled`, bundle ID
   `com.kulturniprehled.kpMobile`, SKU `kp-mobile-001`, primary
   language Czech. App Store Connect → My Apps lists it; if it
   disappears, recreate at <https://appstoreconnect.apple.com>.

2. **Xcode signing** — Team `YOURTEAMID` is pinned in
   `apps/mobile/ios/Runner.xcodeproj/project.pbxproj`. Automatic
   signing is enabled. Don't touch unless the team changes.

3. **App-specific password** — stored in 1Password as
   `Kulturni prehled Apple ID app-specific password` →
   `credential`. Used by `xcrun altool` (see per-release flow below).
   To rotate: <https://appleid.apple.com> → Sign-In and Security →
   App-Specific Passwords → revoke old + create new + overwrite the
   1Password item.

4. **Internal Testing group `Družina`** — Běla is in App Store
   Connect as an **App Manager** team member (Users and Access →
   People). Internal Testing group `Družina` lists her as the only
   tester. **Auto-Distribute new builds** is enabled on the group,
   so every fresh upload pings her TestFlight app within minutes of
   ASC finishing processing. Internal Testing skips Apple's Beta
   App Review entirely.

   Note: Internal Testing requires team membership. Adding
   external-only testers later (anyone not on the ASC team) needs a
   separate External Testing group **with** per-build Beta App
   Review (hours-to-a-day on the first build of each version).

5. **`apps/mobile/ios/ExportOptions.plist`** is committed — Flutter
   reads it via `--export-options-plist=ios/ExportOptions.plist` so
   the IPA export step doesn't fall over on missing dSYMs (`error:
   exportArchive Copy failed` from the `objective_c.framework`
   frame). Key entries: `method=app-store`,
   `signingStyle=automatic`, `teamID=YOURTEAMID`,
   `uploadSymbols=false`. Trade-off: TestFlight / App Store crash
   reports are no longer auto-symbolicated, but mobile crash
   reporting will move to Sentry/GlitchTip anyway (see follow-ups
   in `private/docs/handover.md`).

6. **`Info.plist: ITSAppUsesNonExemptEncryption = false`** — uses
   only standard HTTPS, no proprietary crypto, so we're export-
   exempt. With this flag ASC doesn't prompt for export compliance
   on every upload.

### Per-release steps

```bash
cd apps/mobile
# bump version in pubspec.yaml — `version: 1.0.X+Y` (Y must be unique
# and monotonically increasing per CFBundleVersion)

GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")
ALTOOL_PW=$(op-cache "Kulturni prehled Apple ID app-specific password" credential)

flutter build ipa --release \
  --export-options-plist=ios/ExportOptions.plist \
  --dart-define=KP_API_BASE=https://kulturniprehled.example.com \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID="$GOOG_CLIENT_ID"

xcrun altool --upload-app \
  -f "build/ios/ipa/Kulturni Prehled.ipa" \
  -t ios \
  -u petronijus@example.com \
  -p "$ALTOOL_PW"

unset GOOG_CLIENT_ID ALTOOL_PW
```

That's the full release pipeline. Apple processes the build
(~5–15 min), then the Auto-Distribute setting on `Družina` pushes
it to Běla's TestFlight automatically. No clicks in App Store
Connect, no clicks in Xcode.

### Smoke test on iPhone

- TestFlight on Běla's iPhone → Kulturní Přehled → Update / Install
- Sign in with her Google account (iOS GIDClientID picked up from
  `Info.plist`).
- Agenda + detail + month view + watchlist + stats render
  correctly.
