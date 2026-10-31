# Development

How to set up a machine, what the checks are, and how the repo is wired for
humans and coding agents. The rules themselves are in `AGENTS.md`; releases
are in [`release.md`](./release.md).

## Machines

| Machine | Lanes | Notes |
|---|---|---|
| Linux desktop | everything except iOS | the everyday machine; `just ci` skips `build-ios` and says so |
| MacBook | all (`just ci`) | iOS builds, local TestFlight releases |
| Proxmox MacOS VM | iOS release | headless TestFlight builds (`ios-release-vm` skill) |

There is deliberately no hosted CI: the recipes are the CI, and the
pre-push hook runs the fast lane on every push.

## Toolchain

| Tool | Version | Why pinned |
|---|---|---|
| Flutter | 3.47.5 (`.flutter-version`) | enforced by `environment.flutter` in `pubspec.yaml`. 3.44 moved `CupertinoPageTransitionsBuilder` out of `material.dart` and replaced `ReorderableSliverList.onReorder`; 3.44 cannot `flutter build ios --simulator` on Xcode 27 (`lipo -verify_arch`), 3.47 fixed it |
| Swift Package Manager | disabled | `workmanager_apple`, `flutter_secure_storage` and `flutter_local_notifications` ship only CocoaPods specs; mixed builds fail with `Module 'flutter_timezone' not found`. A per-machine Flutter flag, not a repo file |
| JDK | 25 (≥ 17) | AGP 9.2 needs ≥ 17; the machines share JDK 25 with Pinkni |
| Android SDK | platform `android-36` | Flutter 3.47.5's default `compileSdk` |
| AGP / Gradle / Kotlin | 9.2.1 / 9.4.1 / 2.4.20 | shared with Pinkni; a bump is verified with `just build-android` |
| Python | 3.12 (`apps/api/.python-version`) | the API image is `python:3.12-slim`; tests run on the same version. uv installs it |
| Node | 24 (`apps/api/web/.nvmrc`) | the image builds the SPA on `node:24-slim` |
| Docker | running daemon, `docker login ghcr.io` | pytest starts Postgres and MinIO with testcontainers; `just build-api`. The MinIO image is a private GHCR package ([MinIO image](#minio-image)) |
| ruff | locked in `apps/api/uv.lock` | one version for the API and every script (`uv run --project apps/api ruff`) |
| just, lefthook, gitleaks, ktlint, shellcheck, uv | current | task runner, git hooks, secret scan, Kotlin and shell lint, Python toolchain |
| python3 | ≥ 3.9 | the Claude Code hooks, the PII scan, the script tests and the docs check (standard library only) |
| sops, age, op | current | secrets from the private overlay and 1Password |

`just doctor` checks all of it and prints the fix for anything missing.

### Flutter

```sh
cd "$(flutter --version --machine | jq -r .flutterRoot)" && git fetch --tags && git checkout 3.47.5
flutter config --no-enable-swift-package-manager
```

### macOS

```sh
brew install just lefthook gitleaks ktlint shellcheck uv node@24 sops age cocoapods
```

Xcode from the App Store; Docker Desktop (or OrbStack) for the API tests.

### Linux

`just`, `lefthook`, `gitleaks`, `ktlint` and `uv` from Homebrew on Linux or
their release binaries; `shellcheck` and Docker from apt; Node 24 from
NodeSource or nvm.

### Then, in every clone

```sh
git clone https://github.com/petronijus/kulturniprehled-private.git private   # maintainers
just setup
just secrets-decrypt   # .env for the dev stack (needs the overlay and 1Password)
```

## Checks

| Recipe | Runs | When |
|---|---|---|
| `just check` | format check, `flutter analyze`, ruff + mypy, Biome + tsc, shellcheck, `just lint-docs`, and every test below except builds (~1.5 min, most of it the API tests) | pre-push hook |
| `just check-affected` | `tools/dev/check-affected.sh`: the format check of the changed files, the docs check, shellcheck, and the analyzers and tests of the units changed since the last tree that passed this lane (`apps/mobile`, `apps/api`, `apps/api/web`, the scripts); the whole `just check` when a shared file changed (the justfile, `tools/`, `.claude/hooks`, root config) or nothing has passed yet in this clone | Claude Code Stop hook (waits while background agents are working) |
| `just lint-docs` | `tools/dev/docs-check.py`: every `just` recipe, relative link, heading anchor, repo path in inline code and `@import` the docs name exists; AGENTS.md and CLAUDE.md within 200 lines | pre-commit hook, `just check` |
| `just test-api` | pytest against Postgres 16 and MinIO in testcontainers | API changes |
| `just test-dart` | `flutter test` | app changes |
| `just test-web` | vitest | SPA changes |
| `just test-scripts` | stdlib tests of `kp_validate`, the seat watcher, the claudebox runner and the PII scan | script changes |
| `just ci` | the fast lane plus the debug APK, the SPA bundle, the API image and, on macOS, the iOS build | before a commit that is meant to be pushed |

What the tests cover:

- **API**: every endpoint through the ASGI client against real Postgres and
  MinIO (no DB mocks); sync, auth, PATs and scopes, tickets, season pool and
  scenarios. Coverage goal 80 % overall, 95 % on sync and auth.
- **Mobile**: widgets (agenda, detail, stats), the outbox, auth refresh, the
  notification locale and reschedule-race regressions, and a tripwire on
  the Android manifest's notification receivers.
- **Web**: the planner's domain logic — ISO weeks, violations (mirror of
  `kp_validate.py`), programme keys, the play queue.
- **Scripts**: the season validator, the seat watcher's hall parser, the
  claudebox runner's git handling, the PII scan.
- **Performance** (on demand, not in any lane): `just perf-agenda <device>`
  scrolls a seeded agenda on an Android device or emulator in a profile build while
  the tilt sensor jitters, and writes build/raster frame percentiles to
  `apps/mobile/build/agenda_*.json`. Absolute numbers need a physical phone.
  Without one, an emulator started with `-no-window -gpu
  swiftshader_indirect` still compares a change against its baseline: the
  software rasteriser makes GPU-heavy effects (blur, blend layers) cost in
  proportion. With `-gpu host`, raster time is pinned to vsync and tells
  nothing. Profile builds install as `com.kulturniprehled.kp_mobile.profile`
  next to the Play app. There is no iOS counterpart: an iOS profile build
  shares the TestFlight app's bundle id and would replace it.
- **Not automated**: end-to-end flows on devices. Notifications and
  background sync need a check on a real, locked Android phone
  (`adb shell dumpsys alarm` and `dumpsys activity broadcasts history` show
  whether an alarm was delivered); iOS gets a Simulator smoke test and
  TestFlight on Běla's phone.

## Git hooks (lefthook)

| Hook | Does |
|---|---|
| pre-commit | formats staged files and re-stages them; gitleaks scans the staged diff; the PII scan checks the added lines; the docs check |
| commit-msg | Conventional Commits, subject ≤ 72 characters |
| pre-push | `just check` |

Personal overrides go into `lefthook-local.yml` (gitignored).

### The PII scan

The repository is public. `tools/dev/pii-scan.py` checks every line a commit
adds against the private regex list of the `repo-hygiene` skill
(`~/.claude/skills/repo-hygiene/patterns.txt`, or `$KP_PII_PATTERNS`). The
list never enters this repo. Without the list the scan says it was skipped
and lets the commit through. Lines already in the repo are the monthly
`repo-hygiene` audit's job.

## Secrets

- `.env` is gitignored; the real one is SOPS-encrypted in the private
  overlay (`private/config/env.sops`). `just secrets-decrypt` materialises
  it, `scripts/secrets-edit.sh` changes it; the age key comes from
  1Password.
- The API token for scripting: `op-cache "kulturni-prehled api-token" credential`.
- The Google OAuth client is shared with a sibling project (1Password); only
  the redirect URI is per app.
- Release credentials (keystore, App Store Connect key): `docs/release.md`
  and `private/docs/release-credentials.md`.

## MinIO image

MinIO deleted `minio/minio` and `minio/mc` from Docker Hub on 2026-09-11
(Quay has no tags either). The stack now runs Chainguard's maintained build,
`cgr.dev/chainguard/minio`, **mirrored byte-for-byte into our own GHCR
package** so it cannot disappear again:

```text
ghcr.io/petronijus/minio:RELEASE.2026-09-22T19-25-18Z@sha256:25bc63a89475bc494bfbce9bbeddb0421aece3f3968d77c809db5104d07b4545
```

- The reference lives once, in the `x-minio-image` anchor of
  `infra/docker-compose.yml`; `apps/api/tests/conftest.py` reads it from
  there, so the testcontainers MinIO is the production build too.
- The package is **private**: every machine that pulls it (this one for
  `just test-api` and `just dev-up`, the VM) needs `docker login ghcr.io`
  once.
- One image serves server and client: entrypoint `/usr/bin/minio`, `mc` and
  `sh` (bash) in `/usr/bin` with GNU coreutils, but no curl, wget or `find`
  (the healthcheck is `mc ready local`).
  Chainguard's separate `minio-client` image has no shell, so `minio-init`
  and the backup scripts run this one with an `sh` entrypoint.
- It runs as nonroot `65532`. Volumes written by the old root-running
  official image are handed over by the one-shot `minio-perms` service
  (`chown -R -c`) before every `minio` start; it logs how many entries it
  changed, `0` on an already migrated volume.

To move to a newer build, mirror it under its release tag and bump the
reference:

```sh
crane digest cgr.dev/chainguard/minio:latest            # the new digest
docker run --rm cgr.dev/chainguard/minio@sha256:<digest> --version   # its RELEASE tag
crane copy cgr.dev/chainguard/minio@sha256:<digest> ghcr.io/petronijus/minio:<RELEASE tag>
```

`crane copy` keeps the digest, so the new `tag@sha256:<digest>` goes into the
`x-minio-image` line as is. Then `just test-api`, `just dev-up`, and on the
VM the manual MinIO step in `infra/deploy/README.md`.

## Coding agents

- `AGENTS.md` holds the rules for every agent; Claude Code reads
  `CLAUDE.md`, which imports it.
- `.claude/` (committed): `settings.json` (permissions and hooks),
  `hooks/` (guard and format every write, shell writes included; refuse to
  print key material, also through wrappers and recursive searches, and
  deny a call the guard cannot parse; run `just check` before a turn ends), `agents/` (`test-runner`,
  `test-writer`, `docs-writer`, `integrity-reviewer`), `rules/` (Flutter app, Android,
  iOS, API, web, skills), and `harness-version` — the version of Petr's
  harness standard this repo follows (`/project-setup upgrade` brings it up
  to date).
- The skills in `skills/` are symlinked into `~/.claude/skills/` and are
  global on Petr's machines; a change is live on their next run.
- Personal Claude settings: `.claude/settings.local.json`,
  `CLAUDE.local.md` (gitignored).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `just test-api` says Docker is not running | start the daemon; testcontainers needs it |
| `just test-api` or `just dev-up` cannot pull `ghcr.io/petronijus/minio` (`denied` / `unauthorized`) | the package is private: `docker login ghcr.io -u petronijus` with a PAT that has `read:packages` ([MinIO image](#minio-image)) |
| `fmt-check` / `lint-web` say `node_modules` is missing | `just setup` (or `cd apps/api/web && npm ci`) |
| a Swift file is "skipped" by `format.sh` | swift-format ships with Xcode; run `just fmt` on the MacBook |
| `uv run` reinstalls packages or Python | `apps/api/.python-version` pins 3.12 like the image; the dev tools are the `dev` dependency group, installed by default |
| ruff disagrees between machines | always call it through `uv run --project apps/api ruff` (the locked version), never a global `ruff` |
| `Unresolved reference` in a plugin's Kotlin after a dependency upgrade (seen with `sentry_flutter`) | stale incremental build from the old plugin version: `cd apps/mobile/android && ./gradlew --stop`, then `flutter clean` in `apps/mobile` |
| a scraper run (`fok.sh`) takes minutes | expected: it fetches every detail page |
| the commit is refused with `pii-scan` | replace the value with a placeholder and put the real one in `private/` |
| `docs-check` names a path or recipe that is right in context (another repo's file, a future file in a plan) | write the reference so it cannot be misread, or put `<!-- docs-check: ignore -->` on that line (above a code fence: the whole block); docs that record history go to `EXCLUDE` in `tools/dev/docs-check.py` |
