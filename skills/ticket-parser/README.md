# `ticket-parser` skill

Placeholder. Milestone M4 imports the existing personal Claude Code skill
(currently writing only to Google Calendar) and extends it to call the
Kulturní Přehled API.

When the skill source is added here, it must include:

- `SKILL.md` describing trigger conditions and capabilities (parse ticket,
  create event in KP, upload ticket file, log to `llm_calls`).
- A new capability `kp_create_event` that POSTs to `/v1/events`.
- A new capability `kp_upload_ticket` that uses the presigned-URL flow.
- A bearer token loaded from 1Password (`op-cache "kulturni-prehled api-token" credential`).
- Idempotency: re-running the skill on the same ticket file must not create
  duplicate events (use a stable hash of the ticket payload as a marker).

The skill source lives in this directory and is versioned together with the
backend so the API contract and the skill never drift.
