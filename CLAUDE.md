# Kulturní Přehled — Development Guide

Self-hosted cultural-event tracker shared between two users (Petr + Běla).
Backend in FastAPI, mobile apps in Flutter, LLM-powered ticket ingestion via an
extended Claude Code skill.

## Stack

| Layer        | Choice                                                                |
| ------------ | --------------------------------------------------------------------- |
| Backend      | Python 3.12, FastAPI, SQLAlchemy 2.0 async, PostgreSQL 16, Alembic    |
| Mobile       | Flutter (Android primary, iOS parity), drift (SQLite), Riverpod       |
| Object store | MinIO (S3-compatible), self-hosted                                    |
| LLM          | Anthropic Claude API behind a `LLMProvider` abstraction               |
| Hosting      | Proxmox VM, Docker Compose, Cloudflare Tunnel                         |
| Auth         | Google OAuth2 (PKCE) → backend issues JWT + refresh-token rotation    |
| Push         | APNs (iOS) + FCM (Android) behind `NotificationProvider` abstraction  |
| CI/CD        | None — solo dev, manual release flow documented below                 |

## Language policy

All code, comments, docs, commit messages, and PR descriptions are in **English**.
Only the chat conversation with the user can remain Czech.

## Mobile platform policy

Android is the primary development and testing target — fastest iteration loop.
iOS keeps **full feature parity**, no Android-only features allowed. Every
package choice must work identically on both. Material 3 design system avoids
Cupertino-only widgets while still feeling native enough.

## Repository layout

```
apps/api/          FastAPI service
apps/mobile/       Flutter app (Android + iOS)
packages/          Shared specs / generated clients
skills/            Claude Code skill source (ticket parser)
infra/             Docker Compose, Cloudflare Tunnel, backup scripts
docs/              Architecture, API, sync, deployment docs
```

## Conventions

- **Commits**: [Conventional Commits](https://www.conventionalcommits.org/) —
  `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`, `perf:`, `ci:`.
- **Branches**: `main` is always deployable. Work in `feat/*` or `fix/*` branches,
  open PRs into `main` so each change has a description + release notes get
  auto-generated. Pushing straight to `main` for one-line typo fixes is fine.
- **PR template**: change summary, why, test plan, screenshots for UI changes.

## Code style

- **Python**: ruff + black + mypy `--strict`. Async-only request handlers, never
  call sync DB methods from request paths.
- **Dart**: `dart format`, `flutter_lints` strict, no `dynamic`, no `late`
  unless absolutely required.
- **No comments unless the WHY is non-obvious.** Identifier names carry the
  WHAT; references to tickets/PRs/incidents belong in commit messages.

## Testing strategy

- **Backend** (`apps/api`): pytest + testcontainers (real Postgres + MinIO in
  tests, no DB mocks). Coverage goal 80% overall, 95% on sync + auth.
- **Mobile** (`apps/mobile`): `flutter test` for widgets and business logic,
  `integration_test` for end-to-end flows (login, create event, sync, ticket
  download). Primary target Android emulator + a physical Android device;
  iOS smoke test on Simulator + occasional physical device.
- **End-to-end**: pytest scenario invoking the API the same way the Claude
  skill does, asserting Calendar entry + MinIO blob.

## Definition of done

1. Code written, formatted, lint passes.
2. Tests written and green. Every bug fix adds a regression test.
3. Commit in Conventional Commit format.
4. Push to a feature branch, open PR (or push to `main` for trivial changes).
5. Local checks (next section) green before merge.
6. Manual verification (dev compose up, click through UI or curl endpoint).

## Commit cadence (explicit project policy)

- **After every fix**: commit + push.
- **After every milestone (M0…M8)**: tag (`v0.1.0`, … `v1.0.0`), push the tag,
  publish the signed APK to GitHub Releases (procedure below).
- **Never** `--no-verify`. **Never** force-push to `main`.

## Local pre-merge checklist (no CI runs this for you)

Run these before opening / merging a PR. Same gates the old GitHub Actions
workflows used to enforce.

**Backend** (from `apps/api/`):

```bash
uv run ruff check .
uv run black --check .
uv run mypy src/kp_api
uv run pytest -q          # 60+ tests, ~1 min with warm testcontainer
```

**Mobile** (from `apps/mobile/`):

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test                    # 9+ widget + unit tests
```

If any of those is red, fix before merging — no human is going to catch it
for you on a green-CI prompt.

## Release procedure (signed APK + API redeploy)

The release.yml workflow is **gone**; everything below runs locally.

### 1. Bump version

`apps/mobile/pubspec.yaml` → `version: 1.0.X+Y` (semver + Android version code).
Commit the bump on its own line: `chore(mobile): bump to v1.0.X`.

### 2. Run the pre-merge checklist

See the section above. Both backend + mobile need to be green.

### 3. Tag the release

```bash
git tag -a v1.0.X -m "Short one-line summary of what's in this release"
git push origin v1.0.X
```

### 4. Build the signed APK locally

The release keystore lives at `~/.android/kp-release.keystore`. Local key
properties are at `apps/mobile/android/key.properties` (gitignored). Both are
also stored in 1Password (`Kulturni Prehled Android Release Keystore`) for
recovery.

```bash
cd apps/mobile
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")
flutter build apk --release \
  --dart-define=KP_API_BASE=https://kulturniprehled.example.com \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID="$GOOG_CLIENT_ID"
unset GOOG_CLIENT_ID
mv build/app/outputs/flutter-apk/app-release.apk \
   build/app/outputs/flutter-apk/kp-mobile-v1.0.X.apk
```

Sanity-check the signature SHA-1 (must match the one registered in the
Android OAuth client for `com.kulturniprehled.kp_mobile` — release-key entry
in Google Cloud is `DC:B7:D3:89:9A:A7:79:DF:53:EF:AF:40:3B:DC:7B:BB:9A:44:29:64`):

```bash
$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/kp-mobile-v1.0.X.apk \
  | grep "SHA-1 digest"
```

### 5. Create the GitHub Release with the APK attached

```bash
gh release create v1.0.X build/app/outputs/flutter-apk/kp-mobile-v1.0.X.apk \
  --title "v1.0.X" \
  --generate-notes
```

Běla + Petr download the APK from
<https://github.com/petronijus/kulturniprehled/releases> on their phones.
First install needs "Install unknown apps" toggled on for the browser.

### 6. Backend deploy (only when API changed)

The Proxmox VM builds the API image from source on each upgrade — no GHCR
push needed.

```bash
ssh petronijus@192.0.2.101 '/opt/kp/infra/deploy/upgrade.sh'
```

The script re-reads its own contents at start. If your release also changes
`infra/deploy/upgrade.sh`, run it twice — the first run pulls the new
script, the second uses it.

### 7. Smoke test

- `curl https://kulturniprehled.example.com/healthz` → `200 {"status":"ok",…}`
- Install the new APK on the Pixel, sign in, agenda + detail + month view
  + watchlist + stats all render the way the release notes describe.

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

## iOS release procedure (TestFlight)

iOS distribution lives on the **Mac** — Xcode + CocoaPods can't run on Linux.
Petr's Mac (per the 2026-05-14 toolchain notes in `docs/handover.md`) already
has Flutter 3.41.9, CocoaPods 1.16.2, and the iOS-26-5 Simulator runtime.

### One-time setup (do this once after Apple Developer Program approval)

1. **App Store Connect record**
   - Sign in at <https://appstoreconnect.apple.com> with the Apple ID tied
     to the Developer Program enrollment.
   - **My Apps → +** → New App
   - Platform: iOS
   - Name: `Kulturní Přehled`
   - Primary language: Czech
   - Bundle ID: `com.kulturniprehled.kpMobile` (registered automatically
     on first upload, but you can pre-register at Certificates, Identifiers
     & Profiles → Identifiers).
   - SKU: `kp-mobile-001` (arbitrary, must be unique within the account)

2. **Xcode signing**
   - Xcode → Settings → Accounts → +Apple ID → sign in
   - Open `apps/mobile/ios/Runner.xcworkspace`
   - Select the Runner target → Signing & Capabilities
   - Tick **Automatically manage signing**
   - Pick your Team from the dropdown — Xcode creates the development
     and distribution certificates + provisioning profile on the fly

3. **App-specific password for CLI uploads**
   - <https://appleid.apple.com> → Sign-In and Security → App-Specific
     Passwords → +
   - Label: `kulturni-prehled-upload`
   - Store the generated `xxxx-xxxx-xxxx-xxxx` in 1Password as item
     `Kulturni prehled Apple ID app-specific password`. This is what
     `xcrun altool` needs in step 5 of every release.

4. **Add Bělaberankova@gmail.com as TestFlight tester** (one-time)
   - App Store Connect → your app → TestFlight → Internal Testing →
     Create Group "Družina" → Add Tester → her Apple ID email
   - Internal testers skip Apple's Beta App Review on every upload (the
     first build gets a quick review anyway, takes minutes-to-hours).
   - She'll get an invite mail. Asks her to install **TestFlight** from
     the App Store, then accept the invite — afterwards every new build
     pings her phone with an auto-update.

### Per-release steps (every time you bump the version)

After running steps 1–3 from the Android release procedure above (bump
pubspec, run checklist, tag), continue on the Mac:

```bash
cd apps/mobile
# Same dart-defines as Android — KP_GOOGLE_OAUTH_SERVER_CLIENT_ID is the
# Web client ID; iOS auto-picks the iOS GIDClientID from Info.plist.
GOOG_CLIENT_ID=$(op-cache "Kulturni prehled google Web OAuth client" "client ID")
flutter build ipa --release \
  --dart-define=KP_API_BASE=https://kulturniprehled.example.com \
  --dart-define=KP_GOOGLE_OAUTH_SERVER_CLIENT_ID="$GOOG_CLIENT_ID"
unset GOOG_CLIENT_ID
```

The IPA lands at `build/ios/ipa/kp_mobile.ipa`.

### Upload to TestFlight

Two equivalent paths — pick whichever is less friction:

**A. GUI — Transporter.app** (App Store free download):
- Drag `build/ios/ipa/kp_mobile.ipa` into Transporter
- Click **Deliver**
- Watch the upload progress bar; expect 2–5 minutes

**B. CLI — `xcrun altool`**:

```bash
altool_pw=$(op-cache "Kulturni prehled Apple ID app-specific password" credential)
xcrun altool --upload-app \
  -f build/ios/ipa/kp_mobile.ipa \
  -t ios \
  -u petronijus@example.com \
  -p "$altool_pw"
unset altool_pw
```

### Wait for App Store Connect to process

App Store Connect needs ~5–15 minutes to process the build. You'll get
an email when the build appears under TestFlight → Builds. While
"Processing", testers can't see it; once "Ready to Submit" / "Ready
to Test", it's pushed to anyone in the assigned internal testing group.

For the **very first** build, expect Apple's Beta App Review to take
extra time (~minutes-to-hours). Subsequent builds skip the review.

### Smoke test on iPhone

- Open TestFlight on Běla's iPhone → Kulturní Přehled → Update / Install
- Sign in with her Google account
- Agenda + detail + month view + watchlist + stats render correctly.

## Secrets

- 1Password CLI: `op-cache "kulturni-prehled api-token" credential`.
- No secrets in the repo. `.env.example` is the template; `.env` is gitignored.
- Google OAuth client is reused from a sibling project (key in 1Password) —
  only the redirect URI is added per app.

## Sync invariants (critical, do not violate)

1. Server `change_log.seq` is a monotonic `bigserial` — never decreased, never
   set manually.
2. Client never writes `version` — server increments on every upsert.
3. `op_id` is the idempotency key for `POST /v1/sync/apply`. Retries are safe.
4. Soft delete only: API never hard-deletes; only `deleted_at` is set. A
   nightly batch job purges tombstones older than 90 days.

## Performance budgets

- API endpoint p95 > 200 ms → optimize.
- Mobile cold start > 2 s → optimize.
- N+1 queries are forbidden; always eager-load via `selectinload` /
  `joinedload`.

## Deployment

- Proxmox VM (Ubuntu Server LTS) running `infra/compose.prod.yml`.
- Cloudflare Tunnel exposes two subdomains: `api.kp.*` for the API, and
  `tickets.kp.*` for MinIO signed-URL traffic.
- Nightly `pg_dump` → MinIO `backups/` bucket → `mc mirror` to Backblaze B2
  for offsite. Quarterly test restore drill (script in `infra/backup/`).

## See also

- `README.md` — quick-start, contributors guide.
- `docs/architecture.md` — system architecture, sequence diagrams.
- `docs/sync.md` — sync algorithm, conflict resolution.
- `docs/api.md` — REST API reference (also OpenAPI at `/openapi.json`).
- `docs/deployment.md` — Proxmox VM setup, Cloudflare Tunnel config.
