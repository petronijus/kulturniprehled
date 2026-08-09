# Kulturní Přehled — Development Guide

Self-hosted cultural-event tracker shared between two users (Petr + Běla).
Backend in FastAPI, mobile apps in Flutter, LLM-powered ticket ingestion via an
extended Claude Code skill.

## Stack

| Layer        | Choice                                                                |
| ------------ | --------------------------------------------------------------------- |
| Backend      | Python 3.12, FastAPI, SQLAlchemy 2.0 async, PostgreSQL 16, Alembic    |
| Mobile       | Flutter 3.44.0 (Android primary, iOS parity), drift (SQLite), Riverpod |
| Object store | MinIO (S3-compatible), self-hosted                                    |
| LLM          | Anthropic Claude API behind a `LLMProvider` abstraction               |
| Hosting      | Proxmox VM, Docker Compose, Cloudflare Tunnel                         |
| Auth         | Google OAuth2 (PKCE) → backend issues JWT + refresh-token rotation    |
| Background   | WorkManager (Android) + BGTaskScheduler (iOS), 30-min periodic sync (no APNs / FCM — see `docs/architecture.md`) |
| CI/CD        | None — solo dev, manual release flow documented below                 |

## Language policy

All code, comments, docs, commit messages, and PR descriptions are in **English**.
Only the chat conversation with the user can remain Czech.

## Mobile platform policy

Android is the primary development and testing target — fastest iteration loop.
iOS keeps **full feature parity**, no Android-only features allowed. Every
package choice must work identically on both. Material 3 design system avoids
Cupertino-only widgets while still feeling native enough.

## Toolchain pinning

- **Flutter 3.44.0** across every dev machine (Linux dev box, MacBook,
  Proxmox MacOS VM). The repo no longer builds on 3.41 — between 3.41
  and 3.44 `CupertinoPageTransitionsBuilder` moved out of
  `material.dart`, and `ReorderableSliverList.onReorder` was replaced by
  `onReorderItem`. Pin via `cd $(flutter --version --machine | jq -r
  .flutterRoot) && git checkout 3.44.0`.
- **Swift Package Manager disabled** per machine —
  `flutter config --no-enable-swift-package-manager`. Three of our
  iOS-side plugins (`workmanager_apple`, `flutter_secure_storage`,
  `flutter_local_notifications`) only ship CocoaPods specs; mixed-mode
  builds fail with `Module 'flutter_timezone' not found` errors. This
  is a per-machine flutter config flag, not a repo file, so each dev
  workstation needs to set it once.

## Brand assets pipeline

Brand masters live under `assets-source/brand/` as 1024×1024 PNGs
authored by Petr. **Never invent, regenerate, or "improve" them** — the
contract is in `assets-source/brand/README.md`. Downstream artefacts
(in-app logo, Android `mipmap-*/ic_launcher.png` +
`drawable-*/ic_stat_notify.png`, iOS `AppIcon.appiconset`) are *resized
only* from the masters; the generator never paints pixels. If you need
a new brand asset, ask Petr to drop a new master and only then run the
resize step.

## Repository layout

```
apps/api/          FastAPI service
apps/api/web/      Season-planner SPA (React + Vite, served by the API at /app)
apps/mobile/       Flutter app (Android + iOS)
packages/          Shared specs / generated clients
skills/            Claude Code skill source (ticket parser, digest experts, season planner)
assets-source/     Brand masters (logo, launcher, notif), user-authored
infra/             Docker Compose, Cloudflare Tunnel, backup scripts
docs/              Architecture, API, sync, deployment, handover docs
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

**Web** (from `apps/api/web/` — the season-planner SPA):

```bash
npm run check                   # biome lint+format + tsc --noEmit
npm run test                    # vitest (domain logic: ISO weeks, violations)
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
properties are at `apps/mobile/android/key.properties` (gitignored). The
`Kulturni Prehled Android Release Keystore` 1Password item currently holds
**only the store/key passwords — NOT the `.jks` file or the key alias** (the
keystore exists only on the Linux PC; backing it up is an open TODO). See
[docs/release-credentials.md](./docs/release-credentials.md) for the full
build-credential inventory and per-machine provisioning steps.

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

The image is built **locally** and pushed to GHCR; the VM only pulls
(`scripts/build-push.sh`, then `upgrade.sh` — never `--build` on the VM;
see ai-config `docs/DEPLOY-STANDARD.md`).

```bash
./scripts/build-push.sh
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

iOS distribution needs a Mac because Xcode + CocoaPods can't run on
Linux. Two paths now exist:

- **Local Mac (MacBook).** Original recipe — kept here for the case
  when you're sitting at the MacBook and just want to ship. Petr's
  MacBook should be on Flutter 3.44.0 (the `assets-source/brand`
  contract, the `import 'package:flutter/cupertino.dart'` change to
  `theme.dart`, and the manual-signing pbxproj edits all depend on
  3.44+; see [docs/handover.md](./docs/handover.md) 2026-05-22 entry
  for the MacBook upgrade steps).
- **Headless via Proxmox MacOS VM (`server-mac`, `192.0.2.154`).**
  Documented end-to-end in [docs/handover.md](./docs/handover.md)
  under the 2026-05-22 session — drives the build over SSH from any
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
   in `docs/handover.md`).

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
