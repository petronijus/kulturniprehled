# Sync algorithm

To be written in milestone M2 once the `change_log` table lands.

The agreed approach is a hybrid:

- **Per-entity versioning** — every mutable row carries a server-assigned
  integer `version` that the server increments on each write.
- **Server-authoritative cursor** — a single `change_log(seq BIGSERIAL …)`
  table is the source of truth for ordering. Clients pull with
  `GET /v1/sync?since=<seq>`.
- **Outbox on the client** — pending mutations live in a `pending_ops` drift
  table with a client-generated `op_id` UUID that doubles as the server-side
  idempotency key.
- **Last-Write-Wins for structured fields**, simple merge UI for free-form
  text (notes, reviews).
- **No CRDTs** — overkill for two users with low write contention.

See `apps/api/src/kp_api/sync/` for the implementation once M2 lands.
