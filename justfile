# Kulturní Přehled task runner — https://just.systems. `just` lists the recipes.
# The fast lane (`just check`) is what the pre-push hook and the Claude Code
# Stop hook run; `just ci` is the full gate before a change counts as done.
# There is no hosted CI: these recipes are the CI, run on the Linux desktop
# (everything except iOS) or the MacBook (all lanes).

set shell := ["bash", "-euo", "pipefail", "-c"]

mobile := "apps/mobile"
api := "apps/api"
web := "apps/api/web"

# One ruff for every Python file: the version locked in apps/api/uv.lock.
ruff := "uv run --quiet --frozen --project apps/api ruff"

# List the recipes
default:
    @just --list --unsorted

# ── setup ────────────────────────────────────────────────────────────────

# One-time setup of a clone on a new machine (idempotent)
setup: doctor
    lefthook install
    cd {{mobile}} && flutter pub get
    cd {{api}} && uv sync --frozen
    cd {{web}} && npm ci

# Check this machine against the pinned toolchain
doctor:
    tools/dev/doctor.sh

# ── fast lane (~1 min, no device, no app build) ──────────────────────────

# Formatting, static analysis and every unit test that needs no build
check: fmt-check lint test-dart test-api test-web test-scripts

# Format every source file in place
fmt: _web-deps
    tools/dev/format.sh --all

# Fail if any source file is not formatted
fmt-check: _web-deps
    tools/dev/format.sh --check --all

# Static analysis on every layer
lint: lint-dart lint-py lint-web lint-shell

# Dart analyzer, infos and warnings fatal
lint-dart:
    cd {{mobile}} && flutter analyze --fatal-infos --fatal-warnings

# ruff on all Python (apps/api/pyproject.toml, else ruff.toml) and mypy --strict on the API
lint-py:
    {{ruff}} check --quiet .
    cd {{api}} && uv run --quiet --frozen mypy src/kp_api

# Biome and tsc on the season-planner SPA
lint-web: _web-deps
    cd {{web}} && npm run --silent check

# shellcheck on every tracked shell script
lint-shell:
    git ls-files -z '*.sh' | xargs -0 shellcheck

# Dart widget and unit tests
test-dart:
    cd {{mobile}} && flutter test

# API tests against real Postgres and MinIO (testcontainers)
test-api: _docker
    cd {{api}} && uv run --quiet --frozen pytest -q

# Vitest on the planner's domain logic
test-web: _web-deps
    cd {{web}} && npm run --silent test

# Stdlib tests of the skill, claudebox and dev-tool scripts (they run without pytest there)
test-scripts:
    cd skills/kulturni-sezona/bin && python3 test_kp_validate.py
    python3 tools/dev/test_pii_scan.py
    python3 infra/claudebox/test_seat_watch.py
    bash infra/claudebox/test_lib.sh

# ── full gate ────────────────────────────────────────────────────────────

# Everything: the fast lane plus every build (iOS only on macOS, skipped loudly elsewhere)
ci: check build-android build-web build-api
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$(uname)" == Darwin ]]; then
      just build-ios
    else
      echo "ci: iOS lane (build-ios) SKIPPED on $(uname) — run it on the MacBook or the MacOS VM." >&2
    fi

# Debug APK (Gradle, AGP, every plugin's Android code)
build-android:
    cd {{mobile}} && flutter build apk --debug

# Unsigned iOS device build (CocoaPods, every plugin's iOS code)
build-ios: _macos
    cd {{mobile}} && flutter build ios --debug --no-codesign

# Production bundle of the planner SPA (tsc + vite)
build-web: _web-deps
    cd {{web}} && npm run --silent build

# The API image exactly as scripts/build-push.sh builds it, tagged locally only
build-api: _docker
    docker build --quiet -t kulturniprehled-api:ci -f {{api}}/Dockerfile {{api}}

# ── everyday ─────────────────────────────────────────────────────────────

# Run the app on a device or simulator (flutter run arguments pass through)
run *args:
    cd {{mobile}} && flutter run {{args}}

# Start the dev stack (Postgres, MinIO, API) from infra/docker-compose.yml
dev-up: _env
    docker compose --env-file .env -f infra/docker-compose.yml up -d

# Stop the dev stack (volumes are kept)
dev-down:
    docker compose --env-file .env -f infra/docker-compose.yml down

# Materialise .env from the private overlay (SOPS + age key from 1Password)
secrets-decrypt:
    scripts/secrets-decrypt.sh

# Delete build output (Flutter, the SPA bundle)
clean:
    cd {{mobile}} && flutter clean
    rm -rf {{web}}/dist

# ── guards (private; fail with the fix) ──────────────────────────────────

_docker:
    @docker info >/dev/null 2>&1 || { echo "Docker is not running: start it (Linux: sudo systemctl start docker; macOS: the Docker app)" >&2; exit 1; }

_web-deps:
    @[[ -x {{web}}/node_modules/.bin/biome ]] || { echo "{{web}}/node_modules is missing: run \`just setup\` (or \`cd {{web}} && npm ci\`)" >&2; exit 1; }

_env:
    @[[ -f .env ]] || { echo ".env is missing: run \`just secrets-decrypt\` (needs the private overlay and 1Password)" >&2; exit 1; }

_macos:
    @[[ "$(uname)" == Darwin ]] || { echo "this recipe needs macOS and Xcode" >&2; exit 1; }
