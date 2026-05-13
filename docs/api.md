# API reference

The canonical reference is the OpenAPI document exposed at
`GET /openapi.json` (and a Swagger UI at `GET /docs`).

This file collects out-of-band notes that do not fit into OpenAPI:

- Authentication flow (Google OAuth → backend JWT).
- Sync semantics (cursor, idempotency, conflicts).
- Signed-URL flow for tickets.
- Webhooks consumed (none today; reserved for future scraper integrations).

Sections will be filled in as endpoints land in milestones M1–M8.
