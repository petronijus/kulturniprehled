#!/usr/bin/env bash
# Build the kulturniprehled API image LOCALLY and push it to GHCR. The prod VM
# then just pulls it (infra/deploy/upgrade.sh) — no build on the VM, no CI.
# (The mobile app is built separately with Flutter — see docs/SELF-HOSTING.md.)
#
# Prereqs (on your build machine):
#   - Docker running
#   - logged in to GHCR:  echo "$GHCR_PAT" | docker login ghcr.io -u petronijus --password-stdin
#       (PAT needs write:packages)
#
# Usage:
#   scripts/build-push.sh              # tag = git short sha + :latest
#   KP_API_TAG=v1.2.0 scripts/build-push.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REG="ghcr.io/petronijus/kulturniprehled-api"
TAG="${KP_API_TAG:-$(git rev-parse --short HEAD)}"

# The SPA bakes the Google Web OAuth client id in at build time. Pull it
# from 1Password unless the caller already exported it; an empty value
# still builds (sign-in button errors at runtime until provided).
if [ -z "${VITE_KP_GOOGLE_CLIENT_ID:-}" ] && command -v op-cache >/dev/null 2>&1; then
  VITE_KP_GOOGLE_CLIENT_ID="$(op-cache "Kulturni prehled google Web OAuth client" "client ID" 2>/dev/null || true)"
fi
[ -n "${VITE_KP_GOOGLE_CLIENT_ID:-}" ] || echo "WARN: VITE_KP_GOOGLE_CLIENT_ID empty — SPA login will not work"

echo "→ building ${REG}:${TAG} (+ latest)  [context: apps/api]"
docker build -t "${REG}:${TAG}" -t "${REG}:latest" \
  --build-arg VITE_KP_GOOGLE_CLIENT_ID="${VITE_KP_GOOGLE_CLIENT_ID:-}" \
  -f apps/api/Dockerfile apps/api
docker push "${REG}:${TAG}"
docker push "${REG}:latest"
echo "✓ pushed ${REG}:{${TAG},latest}"
echo "  Deploy on the VM:  KP_API_TAG=${TAG} ./infra/deploy/upgrade.sh   (pulls, no build)"
