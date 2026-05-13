# OpenAPI spec snapshot

The backend's `/openapi.json` is committed here as a versioned snapshot so the
Flutter Dart client (generated in `apps/mobile/lib/data/api_client/generated/`)
stays in sync. Regeneration script lands in milestone M5.

Planned workflow:

```bash
# Backend running locally or in CI
curl -s http://localhost:8000/openapi.json | jq . > openapi.json

# Generate Dart client (run from this directory)
openapi-generator generate -i openapi.json -g dart-dio \
  -o ../../apps/mobile/lib/data/api_client/generated
```

CI fails the PR if `openapi.json` is stale relative to the running API.
