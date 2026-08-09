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

echo "→ building ${REG}:${TAG} (+ latest)  [context: apps/api]"
docker build -t "${REG}:${TAG}" -t "${REG}:latest" -f apps/api/Dockerfile apps/api
docker push "${REG}:${TAG}"
docker push "${REG}:latest"
echo "✓ pushed ${REG}:{${TAG},latest}"
echo "  Deploy on the VM:  KP_API_TAG=${TAG} ./infra/deploy/upgrade.sh   (pulls, no build)"
