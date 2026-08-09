# Kulturní přehled skill suite — operator notes

Two flows feed *Kulturní Přehled* the app:

1. **Season planning** (`/kulturni-sezona`, local, ~once per season) —
   scrapes the whole Sep–Jun season, pushes the candidate pool + ~5
   scenario dramaturgies to the backend, and hands off to the web
   planner at `/app` where Petr finalizes his plan (drag & drop,
   scenario preview/apply). The planner is **home-only**: the API blocks
   `/app` on the public Cloudflare path (`WEB_PUBLIC=false`); reach it at
   `https://kulturniprehled-plan.bastla.com/app` (internal split-horizon
   name — see One-time setup below).
2. **Novelty watching** (`/kulturni-prehled`, weekly, Saturday 11:00
   via `/schedule`) — re-scrapes, diffs against the pool, pushes
   updates, and emails **only newly announced events** with a
   fit-suggestion against the standing plan. It is the only skill in
   the suite that sends email.

## Architecture at a glance

```
ONCE PER SEASON (local)
/kulturni-sezona
   ├─ Skill /<expert> mode=season … → /tmp/kp-season-<id>/<lane>.json
   ├─ merge + dedup_key → PUT /v1/season/plans/{id}/pool
   ├─ scenarios per archetypes.md → bin/kp_validate.py scenario (gate)
   ├─ PUT /v1/season/plans/{id}/scenarios
   └─ POST …/novelties/ack   (so week 1 isn't spammed)
                     │
                     ▼
        Petr finalizes in the SPA (/app) — plan_status on candidates

WEEKLY (cloud /schedule, Sat 11:00 — cloud-routine.md)
/kulturni-prehled (novelty watcher)
   ├─ experts in weekly mode (pool-aware enrichment = cheap)
   ├─ diff by dedup_key → novelties; ticket watchdog on plan events
   ├─ PUT pool (grows elektronika/film coverage all season)
   ├─ bin/kp_validate.py fit → „kam by to sedlo"
   ├─ email novelties (HMAC 👍/👎, /v1/digest/send in cloud)
   └─ POST …/novelties/ack   (only after a successful send)
```

## The constraint canon

Every rule lives in **one** place:
[`../kulturni-sezona/bin/kp_validate.py`](../kulturni-sezona/bin/kp_validate.py).
The SPA mirrors it client-side (`apps/api/web/src/domain/violations.ts`)
— change the canon first, mirror second.

| Rule | Value | season_event exempts? |
| --- | --- | --- |
| Week cap (incl. booked events) | ≤ 2 / ISO week | **never** |
| Min gap between events | ≥ 2 calendar days | yes (gap only) |
| Same work per season | never twice | — |
| Same work, same calendar year (history) | hard veto | — |
| Same work, last year | warn („jen pokud výjimečné") | — |
| Price (VIP-clamped midpoint) | > 3000 Kč out, 2000–3000 warn | — |
| Blocked days / timed conflicts | `[start−2h, end+1h]` | — |

Violations are hard gates for scenarios; in the SPA they are advisory
(Petr overrules by design).

## Experts

| Expert | Sources | Season coverage | Status |
| --- | --- | --- | --- |
| `klasika-expert` | 5 static scrapers (`ensembles/*.sh`) + festival WebFetch + Spotify + Discogs | deep (full season) | active |
| `elektronika-expert` | WebFetch only (clubs + RA/GoOut fallback) | ~60 days rolling → reserved slots | active |
| `divadlo-expert` | WebFetch only (theatre programmes) | deep (full season) | **disabled — fill preferences.md TODOs** |
| `film-expert` | WebFetch only (art cinemas + festivals) | 2–4 weeks → reserved slots | **disabled — fill preferences.md TODOs** |

Enable/disable in [`active-experts.txt`](./active-experts.txt) — one
name per line, `#` comments. Experts take
`args: "mode=season season=<id>"` from the orchestrator; no args =
weekly. Adding a new expert = new `skills/<lane>-expert/` per the
divadlo template + symlink + uncomment. No aggregator changes.

## One-time setup

1. Symlinks (per dev machine):

   ```bash
   for s in kulturni-prehled kulturni-sezona klasika-expert \
            elektronika-expert divadlo-expert film-expert; do
     ln -sfn ~/Documents/Dev/kulturniprehled/skills/$s ~/.claude/skills/$s
   done
   ```

2. **Cloud PAT** for the /schedule routine — scopes
   `digest:read feedback:sign digest:send season:read season:write`:

   ```bash
   ./scripts/mint-pat.sh   # then update the routine's stored KP_DIGEST_TOKEN
   ```

3. **SPA access** — the planner is home-only and **login-less**: set
   `WEB_TRUSTED_LAN=true` in `/opt/kp/.env` (direct requests from the
   home network authenticate automatically with season-only scopes;
   Cloudflare-tunneled requests never do). Reach it at
   `http://192.168.20.101:18000/app`, over Tailscale, or — optional
   HTTPS niceness — `https://kulturniprehled-plan.bastla.com/app`:

   - OPNsense host override `kulturniprehled-plan.bastla.com` →
     192.168.20.101 (done 2026-08-09; internal-only, no public record).
   - On the VM: `docker compose -f docker-compose.yml -f
     compose.internal-web.yml up -d caddy` with `KP_INTERNAL_HOSTNAME` +
     `CLOUDFLARE_DNS_API_TOKEN` in `/opt/kp/.env` (LE cert via DNS-01).
   - Away from home the name resolves as long as the tailnet uses the
     home DNS (split DNS / subnet router); otherwise use the LAN URL
     over Tailscale directly.

   No Google OAuth involvement anywhere — the network is the auth.

4. The `/schedule` routine (Sat 11:00 Europe/Prague) runs
   [`cloud-routine.md`](./cloud-routine.md) — it survives this rework
   unchanged as an entry, only the playbook content changed.

## Operator calendar

- **Spring / late August**: run `/kulturni-sezona` for the coming
  season; review scenarios in the SPA; apply + tune the plan.
- **Anytime**: adjust the plan in the SPA; the weekly email reflects it
  next Saturday.
- **Saturday 11:00**: novelty email arrives automatically. 👍/👎 links
  feed the feedback loop (`/v1/feedback/history`).
- **June/September handover**: creating the new season archives the old
  one (`archive_current: true`) — deliberate, the orchestrator asks
  first.

## Day-to-day recipes

- Novelty check right now: `/kulturni-prehled`.
- Lane snapshot in chat, no email: `/klasika-expert` (or any expert).
- Re-scrape the season after fixing a scraper: `/kulturni-sezona`
  (idempotent — plan state survives, scenarios re-validate).
- Broken scraper symptom: a lane's novelty count collapses while the
  site works in a browser → check `/tmp/kp-klasika-<ensemble>.err`,
  fix the parser in `../klasika-expert/ensembles/<e>.sh`.
