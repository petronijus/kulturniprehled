# Architecture

High-level architecture for Kulturní Přehled. Full implementation plan lives
in `~/.claude/plans/` and was approved before the first commit; this document
will be filled in incrementally as milestones land.

## Components

```
[Mobile iOS/Android] ──HTTPS──┐
                              │
[Claude skill on desktop] ────┼──> [Cloudflare Tunnel] ──> [api.kp.*] FastAPI
                              │                       └──> [tickets.kp.*] MinIO (signed URLs)
                              │
                              └── push notif <── APNs/FCM <── FastAPI worker

FastAPI ──> PostgreSQL  (events, sync log, users, costs, recommendations)
        ──> MinIO       (ticket PDFs, posters)
        ──> Anthropic   (ticket parsing, future embeddings)
        ──> Google Cal  (one-way sync, idempotent via extendedProperties)
```

## Why this shape

- **Self-hosted on Proxmox** — data sovereignty, no SaaS bill.
- **Single shared workspace** — Petr + Běla see the same agenda; a real
  multi-tenant model is unnecessary for the foreseeable horizon.
- **Offline-first mobile** — tickets must be readable at venues where signal
  is unreliable. A signed-URL flow with local AES-GCM-encrypted cache solves
  that without bloating the API event loop with binary streaming.
- **One-way Google Calendar sync** — Google Calendar cannot represent
  tickets, costs or ratings; round-tripping would silently lose data.

## To be expanded

- Sequence diagrams for: ticket ingestion via skill, offline edit + reconcile,
  monthly calendar pull.
- Operational diagrams: backup, restore drill, tunnel topology.
