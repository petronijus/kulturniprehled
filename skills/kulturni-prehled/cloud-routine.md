# Kulturní přehled — cloud routine playbook

Self-contained playbook for the **weekly digest running as a remote
`/schedule` routine** (Anthropic cloud), as opposed to the local
`kulturni-prehled` skill that runs on Petr's PC.

The difference is the environment. The remote agent has **only** a git
checkout of this repo plus the claude.ai connectors — **no** `op`
(1Password), **no** SSH to the prod VM, **no** local `google-workspace`
MCP, and it **cannot** invoke other skills via the Skill tool (the
`~/.claude/skills` symlinks don't exist in the cloud). Everything that
the local skill did through those is replaced here by:

| Local skill used… | Cloud routine uses instead… |
| --- | --- |
| `op` token + raw `/v1/events`, `/v1/feedback/history`, `jq`/`date` math | **`GET /v1/digest/context`** — server precomputes balance, booked list, feedback sentiment |
| `op` Discogs token + `api.discogs.com` pagination | **`discogs` field of `/v1/digest/context`** — server fetches + caches the collection; no Discogs token or `api.discogs.com` egress needed here |
| `ssh` to prod for `API_JWT_SECRET` to sign feedback links | **`POST /v1/feedback/sign`** — server signs them |
| `Skill` tool → `klasika-expert` | read `skills/klasika-expert/SKILL.md` + `preferences.md` and **execute its logic inline** |
| local `google-workspace` MCP | claude.ai **Gmail** + **Google Calendar** connectors |
| Spotify via local config | claude.ai **Spotify** connector |

## Inputs handed to you in the task message

- `KP_DIGEST_TOKEN` — a bearer PAT scoped to **only** `digest:read` and
  `feedback:sign`. It cannot read or mutate anything else. Send it as
  `Authorization: Bearer $KP_DIGEST_TOKEN`.
- `KP_API_BASE` — `https://kulturniprehled.example.com` (public via
  Cloudflare Tunnel; reachable from the cloud).

Never print the token to chat, never write it to a repo file.

## Steps

### 1. Pull the precomputed context

```bash
curl -sS -H "Authorization: Bearer $KP_DIGEST_TOKEN" \
  "$KP_API_BASE/v1/digest/context?horizon_days=180&lookback_days=180"
```

Returns: `digest_week` (e.g. `CW22`), `balance.multiplier` per lane,
`balance.hint` (Czech), `booked[]` (title + starts_at + category for the
next 180 days), `feedback.lane_sentiment` (per-lane multiplier),
`feedback.recent_downvoted_titles`, and **`discogs`** — Petr's vinyl
collection taste map (`{username, release_count, artists[], releases[]}`
with `releases[] = {title, artists[], year}`), or `null` when the
backend has no Discogs token. **This replaces steps 3, 3b, the
booked-dates fetch, and the expert's own Discogs fetch (4b) of the local
skill.** Don't recompute any of it.

### 2. Run the active experts inline

Read `skills/kulturni-prehled/active-experts.txt` for the active lanes
(currently just `klasika-expert`). For each, **read its `SKILL.md` +
`preferences.md` and perform its candidate-gathering inline**:

- Taste profile → claude.ai **Spotify** connector (search/library) plus
  the hand-edited `preferences.md`, plus the **`discogs` field from step
  1** as `$DISCOGS_TASTE` (the long-term anchor — `artists[]` for
  composer presence, `releases[]` for specific work matches). **Skip the
  expert's SKILL.md step 4b `api.discogs.com` fetch entirely** — it's
  unreachable here and already served by the context. Treat the Discogs
  profile qualitatively, never as scores. If `discogs` is `null`, note it
  as a missing source and rank on Spotify + preferences alone.
- Concert listings → `WebFetch` the orchestra / festival URLs the expert
  SKILL lists (and its static-scraper targets — fetch them the same way).
- Exclude anything already in `booked[]` from step 1 (dedup).
- Produce the same ranked candidate JSON shape the expert documents
  (`title`, `starts_at`, `score`, `why_cs`, `venue`, `url`,
  `season_event`, `source_name`/`source_type`, …).

If an expert yields nothing, log it and continue — a short email beats a
broken one.

### 3. Merge + score

For each candidate compute
`weighted_score = score × balance.multiplier[lane] × feedback.lane_sentiment[lane].multiplier`.
If the title is in `feedback.recent_downvoted_titles`, multiply by 0.2.
Sort descending.

### 4. Calendar conflict check (Google Calendar connector)

Pull the shared **Kocourek&Prdelčička** calendar over the next 180 days
via the claude.ai Google Calendar connector (account that owns the
calendar). Drop candidates that fall on an all-day/holiday-blocked day or
overlap a timed event (`[start−2h, end+1h]`). Apply the same vacation
title heuristic as the local skill's step 4b. If the connector isn't
available, **skip this step gracefully** and note it in the email footer.

### 5. Spacing rule + cap

Identical to the local skill step 5, using `booked[]` as the existing
events: **≤ 2 picks per ISO week** (no season override on the cap),
**≥ 2 calendar-day gap** between any two (`season_event: true` overrides
only the gap, never the cap), **global cap 5**. Strong candidates
(score ≥ 0.70) dropped by step 4 or 5 become **notable mentions** (max 3)
with a Czech `drop_reason`.

### 6. Sign feedback links

```bash
curl -sS -X POST -H "Authorization: Bearer $KP_DIGEST_TOKEN" \
  -H "Content-Type: application/json" \
  "$KP_API_BASE/v1/feedback/sign" \
  -d '{"week":"CW22","items":[{"title":"…","lane":"klasika"}, …]}'
```

Returns `url_up` / `url_down` per item. This replaces the local skill's
step 7 (no JWT secret needed here).

### 7. Render + send the email

Reuse the **exact HTML template and subject** from
`skills/kulturni-prehled/SKILL.md` step 8 (`Kulturní přehled — týden
CW{week}`, `balance.hint` in the subheader, the per-pick card with the
signed 👍/👎 links, notable-mentions block). Send a **real email** (not a
draft) via the claude.ai **Gmail** connector:

- **to:** `petronijus@example.com` (never the example.com work address)
- **from:** the connected Gmail account

If the send fails, write the rendered HTML to the run log so the digest
isn't lost.

### 8. Report

Print a one-line summary: how many picks sent, the lane mix, and
`balance.hint`. Communicate in Czech in any chat output.

## Guardrails

- Read-only token: you can call `GET /v1/digest/context` and
  `POST /v1/feedback/sign` and nothing else on the KP API — don't try
  other endpoints, they'll 403.
- One email per run, max ~5 picks, never relax the spacing rule to pad
  the list.
- Don't run more than once per day (external scrapes + connectors).
