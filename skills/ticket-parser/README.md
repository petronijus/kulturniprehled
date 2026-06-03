# `kulturni-prehled-ingest` Claude Code skill

End-to-end ingestion of downloaded cultural-event tickets:

1. Reads the PDFs from `~/Downloads`.
2. Extracts the metadata (performer/title, date, venue, seats).
3. Looks up MHD travel time from Svatovítská 16 to the venue.
4. Creates the event in Kulturní Přehled (`POST /v1/events`).
5. Uploads each ticket to KP via presigned MinIO URL.
6. Builds or updates a Spotify playlist for concert events (step 8.5).
7. Mirrors to Google Drive.
8. Creates the event in the shared Google Calendar.
9. Emails Běla.

The KP-side steps are the new bit; the Drive/Calendar/Gmail steps preserve
the existing personal workflow that predates this project.

## Installation

The canonical skill source lives here, inside the `kulturniprehled` repo so
it is versioned together with the API contract it speaks to. To make it
invokable from Claude Code, symlink it into the user's skills directory:

```bash
ln -sfn \
    ~/Documents/Dev/kulturniprehled/skills/ticket-parser \
    ~/.claude/skills/kulturni-prehled-ingest
```

(In this dev box the same symlink already exists under
`~/Documents/Dev/ai-config/.claude/skills/kulturni-prehled-ingest`.)

## Prerequisites

- Docker + Docker Compose
- The KP backend running locally (`docker compose --env-file .env -f infra/docker-compose.yml up -d`)
- 1Password CLI signed in (`op-cache` helper available)
- One-time setup: mint a Personal Access Token, store in 1Password
  - `./scripts/mint-pat.sh petr@example.com 'desktop-skill'`
  - The script prints the JWT to stdout. Pipe into 1Password:
    ```bash
    PAT=$(./scripts/mint-pat.sh petr@example.com 'desktop-skill')
    op item edit 'Kulturni Prehled API Token' "credential=$PAT"
    ```
- One-time Spotify Web API setup (for the concert-playlist step):
  1. Create an app at <https://developer.spotify.com/dashboard> —
     name `Kulturni Prehled`, redirect URI `http://127.0.0.1:8888/callback`.
  2. Authorize once in a browser (replace `$CLIENT_ID`):
     `https://accounts.spotify.com/authorize?client_id=$CLIENT_ID&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback&scope=playlist-modify-public%20ugc-image-upload`
     and copy the `code` query param off the redirect URL — nothing listens on `127.0.0.1:8888`, so the browser will show a connection-refused page; copy the `code` parameter from the address bar anyway.
  3. Exchange the code for a refresh token:
     ```bash
     curl -sS -X POST https://accounts.spotify.com/api/token \
       -u "$CLIENT_ID:$CLIENT_SECRET" \
       -d grant_type=authorization_code -d code="$CODE" \
       -d redirect_uri=http://127.0.0.1:8888/callback | jq -r .refresh_token
     ```
  4. Store all three in 1Password item `Spotify Web API (Kulturni Prehled)`
     with fields `client_id`, `client_secret`, `refresh_token`.

## How it authenticates

The skill resolves the bearer token in this order:

1. `op-cache 'Kulturni Prehled API Token' credential` (recommended)
2. `KP_API_TOKEN` from the repo `.env`

The token is a long-lived JWT (`type=pat`) signed by the API and tracked
in the `personal_access_tokens` table for revocation. Revoke a leaked
token via `docker compose exec api python -m kp_api.cli` (revoke command
coming in M5).

## API base URL

The skill reads `KP_API_BASE`, defaulting to `http://localhost:18000`.
In production set it to the Cloudflare-tunnel-fronted host
(`https://api.kp.example.com`) in your shell profile or 1Password.

## Why not let the skill call `/v1/sync/apply`?

Creating tickets requires a presigned-URL round trip that is by nature
online. There is no reason to wrap ticket-creation in the outbox; offline
edits / deletes go through the outbox once the Flutter app lands (M5+).
