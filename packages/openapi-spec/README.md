# OpenAPI spec

No snapshot of the schema is committed here. The bootstrap planned one, plus
a Dart client generated from it with `openapi-generator`; milestone M5 wrote
the client by hand instead, and neither was ever added.

- **The schema** is served live by the API: `GET /openapi.json` (Swagger UI
  at `GET /docs`). [`docs/api.md`](../../docs/api.md) is the prose reference
  and names the URLs for prod and the dev stack.
- **The Dart client** is hand-written:
  `apps/mobile/lib/data/api_client/kp_client.dart` (Dio, with the
  bearer-token interceptor and the refresh-token rotation).
- **Contract safety** comes from the tests, not from a generated client: the
  API tests exercise every endpoint through the ASGI client, and the mobile
  tests cover the client's auth and sync paths (`just test-api`,
  `just test-dart`).
