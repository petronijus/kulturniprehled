# Kulturní přehled — cloud routine playbook

Self-contained playbook for the **weekly novelty watcher running as a
remote `/schedule` routine** (Anthropic cloud), as opposed to the local
`kulturni-prehled` skill that runs on Petr's PC. **Season planning
(`/kulturni-sezona`) is local-only** — it needs `op`, the
`ensembles/*.sh` scrapers and a full-power PAT; this routine never
attempts it.

The difference is the environment. The remote agent has **only** a git
checkout of this repo plus the claude.ai connectors — **no** `op`
(1Password), **no** SSH to the prod VM, **no** local `google-workspace`
MCP, and it **cannot** invoke other skills via the Skill tool (the
`~/.claude/skills` symlinks don't exist in the cloud). Everything that
the local skill did through those is replaced here by:

| Local skill used… | Cloud routine uses instead… |
| --- | --- |
| `op` token | `KP_DIGEST_TOKEN` from the task message |
| `Skill` tool → experts | read each expert's `SKILL.md` + `preferences.md` and **execute its weekly-mode logic inline** |
| local `google-workspace` MCP (calendar + Gmail) | claude.ai **Google Calendar** connector; email via **`POST /v1/digest/send`** |
| Spotify via local config | claude.ai **Spotify** connector |
| `ssh` to prod for `API_JWT_SECRET` | **`POST /v1/feedback/sign`** — server signs the 👍/👎 links |
| `api.discogs.com` (klasika taste anchor) | **`discogs` field of `GET /v1/digest/context`** — never fetch discogs directly, it's unreachable here |
| local `python3 …/kp_validate.py` | same file from the **git checkout**: `python3 skills/kulturni-sezona/bin/kp_validate.py` (stdlib-only, runs anywhere) |

## Inputs handed to you in the task message

- `KP_DIGEST_TOKEN` — a bearer PAT scoped to `digest:read`,
  `feedback:sign`, `digest:send`, `season:read`, `season:write`.
  The season scopes cover the pool read/refresh and the novelty
  cursor; everything else on the API 403s. Send as
  `Authorization: Bearer $KP_DIGEST_TOKEN`.
- `KP_API_BASE` — `https://kulturniprehled.example.com` (public via
  Cloudflare Tunnel; reachable from the cloud).

Never print the token to chat, never write it to a repo file.

## Steps

Follow `skills/kulturni-prehled/SKILL.md` (the novelty-watcher flow) with
these substitutions:

### 1. Season + context

- `GET /v1/season/plans/current` — 404 → report „Žádná aktivní sezóna"
  and stop (no email).
- Page through `GET /v1/season/plans/{id}/pool?limit=1000` for the pool,
  `GET …/plan` + `GET …/scenarios` for the standing plan and the applied
  scenario's `reserved_slots`.
- `GET /v1/digest/context?horizon_days=180&lookback_days=180` for
  `booked[]`, `feedback.lane_sentiment`, `recent_downvoted_titles`,
  `balance.hint` and the `discogs` taste map (for inline expert
  ranking).

### 2. Run the active experts inline (weekly mode)

Read `skills/kulturni-prehled/active-experts.txt` for the active lanes.
For each, read its `SKILL.md` + `preferences.md` and perform its
candidate gathering inline in **weekly mode** (default — the rolling
window, 8–12 candidates): Spotify connector for taste, `WebFetch` for
programme URLs **and** the static-scraper targets (fetch them the same
way — `ensembles/*.sh` don't run here), pool-aware enrichment (skip
detail fetches for dedup keys already enriched in the pool). Emit the
expert's documented JSON shape. An expert yielding nothing → log and
continue.

### 3. Diff, push, watchdog

Exactly as SKILL.md step 4: compute dedup keys (recipe in
`skills/kulturni-sezona/SKILL.md`), novelties = keys missing from the
pool, push the whole scraped set via `PUT …/pool` (chunks ≤100),
collect ticket-watchdog flips (`selected` + `false→true`).

### 4. Score + fit

As SKILL.md step 5, with the validator from the checkout:

```bash
python3 skills/kulturni-sezona/bin/kp_validate.py fit \
  --candidate novelty.json --plan plan.json \
  --context context.json --blocked blocked.json
```

`blocked.json` comes from the **Google Calendar connector** (shared
Kocourek&Prdelčička calendar, same classification rules); connector
unavailable → empty blocked set + a footer note.

### 5. Compose + sign + send

- Email content per SKILL.md step 6 (novelties only, fit lines,
  watchdog section, ≤3 notable mentions, zero-novelty → no email).
- Sign links via `POST /v1/feedback/sign` (never compute HMACs here).
- **Send via `POST /v1/digest/send`** (subject
  `Kulturní přehled — novinky, týden CW{week}`; recipient is
  server-side). `503`/`502` → Gmail **draft** via the connector + dump
  the HTML to the run log, and treat the send as FAILED for step 6.

### 6. Ack

Successful send (or a genuine zero-novelty week) →
`POST /v1/season/plans/{id}/novelties/ack {"through": <now iso>}`.
Failed send → **no ack**, the novelties resurface next week.

### 7. Report

One Czech line: novelty count, sent count, pool delta, watchdog count,
`balance.hint`.

## Guardrails

- Narrow token: digest + season scopes only; other endpoints 403.
- One email per run; only novelties — never re-recommend the pool.
- The season pool upsert is additive — the routine can never delete or
  touch Petr's plan state (the API enforces it, but don't try either).
- Don't run more than once per day (external scrapes + connectors).
