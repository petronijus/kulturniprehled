---
name: kulturni-sezona
description: Season planner for Kulturní Přehled. Runs every domain expert in season mode, merges their candidates into the backend season pool, generates ~5 scenario dramaturgies per archetypes.md, validates each with bin/kp_validate.py, and pushes pool + scenarios to the KP API for Petr to finalize in the web planner (/app). Sends no email. Local-only — needs op, ensembles/*.sh scrapers and a full-power PAT; the cloud routine never runs this. Trigger phrases - "naplánuj sezónu", "season plan", "sezónní scrape".
---

## Task

Build (or refresh) the season-wide candidate pool and the scenario set for
the current cultural season, then hand off to the SPA. This is the
once-per-season heavy run (spring / late summer); the weekly
`kulturni-prehled` novelty watcher keeps the pool topped up afterwards.

**The pool is incremental by nature.** Orchestras and theatres publish full
seasons in spring — klasika/divadlo come back deep. Clubs publish 1–2
months ahead, cinemas 2–4 weeks — elektronika/film come back sparse, and
scenarios express the gap as `reserved_slots`, never as invented events.

### API contract (single edit point)

All season endpoints live under `/v1/season` and need a `season:write`
capable token (the local unrestricted PAT qualifies):

- `GET  /v1/season/plans/current` → active season `{id, label, starts_on, ends_on, novelty_ack_at}` (404 = none)
- `POST /v1/season/plans` `{label, starts_on, ends_on, archive_current}` (409 `active_season_exists` without the flag)
- `PUT  /v1/season/plans/{id}/pool` `{items: [CandidateUpsert]}` → `{created, updated, unchanged, total}`
- `GET  /v1/season/plans/{id}/pool?limit=1000&offset=N` → `{items, total}` (enrichment check)
- `PUT  /v1/season/plans/{id}/scenarios` `{scenarios: [{name, description_cs, rank, generated_at, candidate_keys, reserved_slots}], replace: true}`
- `POST /v1/season/plans/{id}/novelties/ack` `{through: <iso>}` — call after the initial push so week one's novelty email doesn't replay the whole pool

`CandidateUpsert`: `{dedup_key, lane, title, starts_at, ends_at?, venue?,
url?, price_czk?, program?, detail?, enriched_at?, score?, why_cs?,
source_type?, source_name?, season_event?, tickets_available?}`.

**`dedup_key` recipe (identity across re-scrapes — never change casually):**

```python
import hashlib, re, unicodedata
def normalize(s):
    s = unicodedata.normalize("NFD", s.lower())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", " ", s)).strip()
def dedup_key(lane, title, starts_at_date):
    return hashlib.sha256(f"{lane}|{normalize(title)}|{starts_at_date}".encode()).hexdigest()[:64]
```

### 0. Resolve season + auth

```bash
KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.example.com}"
KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --fields label=credential --reveal)"
# Cloudflare WAF: every curl needs -A 'kp-skill/1.0'.

SEASON_ID_LABEL=$(python3 -c "
from datetime import date
t = date.today()
y = t.year if t.month >= 7 else t.year - 1
print(f'{y}-{str(y+1)[2:]}')")   # e.g. 2026-27
SEASON_DIR=/tmp/kp-season-${SEASON_ID_LABEL}
rm -rf "$SEASON_DIR" && mkdir -p "$SEASON_DIR"
```

Resolve the backend season: `GET /v1/season/plans/current`. If 404 or the
label differs from `$SEASON_ID_LABEL`, create it (label `2026/27`, window
Sep 1 – Jun 30, `archive_current: true` **only after telling Petr** — the
handover archives his old plan). Store the UUID as `$SEASON_UUID`.

### 1. Assemble context artifacts

Write these into `$SEASON_DIR`; they feed scenario generation AND the
validator:

- `context.json`:
  - `booked` ← `GET /v1/digest/context?horizon_days=330&lookback_days=365`
    (scope-free with the local PAT) — take the `booked` array verbatim.
  - `history_works_this_year` / `history_works_last_year` ← from the same
    context response's booked/history plus `GET /v1/events` queries as in
    klasika-expert step 6; reduce each attended concert program to
    normalized `"composer|work"` strings. When a historical event has no
    program metadata, match on title fragments — better a fuzzy entry than
    a missed hard veto.
- `blocked.json` ← the shared **Kocourek&Prdelčička** calendar over the
  whole season window via the workspace MCP
  (`mcp__google-workspace__get_events`, `user_google_email`
  `petronijus@example.com`, calendar id in `kulturni-prehled/SKILL.md`
  step 4b). Classify exactly as the aggregator's step 4b does: all-day
  spans + vacation-regex titles → `blocked_days`; timed events →
  `conflicts` `{start_iso, end_iso, title}`.

### 2. Run experts in season mode

```bash
EXPERTS=$(grep -v '^#' ~/Documents/Dev/kulturniprehled/skills/kulturni-prehled/active-experts.txt | sed '/^$/d')
```

For each expert, call the `Skill` tool:
`Skill(skill: "<expert>", args: "mode=season season=${SEASON_ID_LABEL}")`.
Each writes `$SEASON_DIR/<lane>.json` (lane = name minus `-expert`).
Missing or empty lane file → warn and continue (expected for divadlo/film
until their preferences are filled, and elektronika is always partial).

**Source health gate:** before pushing, compare each lane's candidate count
with the current pool (`GET pool?lane=<lane>` total). A lane returning
< 30 % of its existing pool size means a scraper probably broke — warn
loudly in the report. The pool upsert is additive-only, so a broken scrape
can never delete anything; it can only fail to add.

### 3. Merge + push the pool

Concatenate lane files, compute `dedup_key` per candidate (recipe above),
drop intra-run duplicates (same key from two sources — keep the richer
record), pack lane-specific fields (`soloists`, `conductor`, `director`,
`production`, `year`) into `detail`, set `enriched_at` for candidates whose
program came from a detail-page fetch. Write `$SEASON_DIR/pool.json`
(array of CandidateUpsert objects).

Push in chunks of ~100:

```bash
jq -c '[_chunk]' … | curl -sS -A 'kp-skill/1.0' -X PUT \
  -H "Authorization: Bearer $KP_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"items\": $CHUNK}" "$KP_API_BASE/v1/season/plans/$SEASON_UUID/pool"
```

Sum the `{created, updated, unchanged}` echoes; retry a failed chunk once,
then report it. After the LAST chunk of an **initial** season push, ack the
novelty cursor: `POST …/novelties/ack {"through": "<now>"}` — otherwise
Saturday's watcher emails the entire pool as "news".

### 4. Generate scenarios (LLM step — you are the LLM)

Read `archetypes.md`. For each archetype, select events from
`$SEASON_DIR/pool.json` honoring the brief: 25–35 events, reserved slots
for sparse lanes, per-event Czech `why_cs`, scenario `motto_cs`. Use
`context.json` history for era dramaturgy. Write
`$SEASON_DIR/scenario-<archetype>.json`:

```json
{"archetype": "vyvazeny-mix", "title_cs": "Vyvážený mix", "motto_cs": "…",
 "events": [{"dedup_key": "…", "why_cs": "…"}],
 "reserved_slots": [{"lane": "elektronika", "month": "2026-11", "note_cs": "…"}]}
```

### 5. Validate — the gate no scenario skips

```bash
python3 ~/Documents/Dev/kulturniprehled/skills/kulturni-sezona/bin/kp_validate.py \
  scenario --scenario "$SEASON_DIR/scenario-<a>.json" --pool "$SEASON_DIR/pool.json" \
  --context "$SEASON_DIR/context.json" --blocked "$SEASON_DIR/blocked.json"
```

On violations: fix the scenario (swap the event for another date of the
same production, drop the weaker of a colliding pair, move month focus),
re-run. **Max 3 iterations per scenario**; if violations persist, drop the
offending events and note it in the scenario's `motto_cs` suffix
`(kráceno validátorem)`. Warnings are allowed and travel with the scenario.
**Never push a scenario with violations.**

### 6. Push scenarios

Map each scenario file to the API shape — `name` = `title_cs`,
`description_cs` = `motto_cs`, `rank` = archetype order in archetypes.md,
`candidate_keys` = the events' dedup keys, `generated_at` = now — and PUT
all of them in one request with `replace: true`.

### 7. Report (Czech, chat only — no email, ever)

- Pool per lane: counts + coverage window, e.g. „elektronika: 9 akcí,
  pokrývá jen září–říjen — pool se doplňuje týdně".
- One line per scenario: name, event count, reserved slots, validator
  iterations used.
- Source health warnings from step 2.
- Finish with the SPA link: `https://kulturniprehled-plan.bastla.com/app`
  (**home-only** — split-horizon DNS name, works on LAN and over
  Tailscale-with-home-DNS; the public Cloudflare path 404s `/app` by
  design).

## When to use

- Once per season (spring for the next season, or late summer catch-up).
- Re-runnable anytime: pool upsert is idempotent, scenarios replace by
  name, Petr's plan state on candidates is never touched by ingest.

## When NOT to use

- Not from the cloud routine (no `op`, no ensembles/*.sh, no full PAT).
- Not weekly — that is `kulturni-prehled`'s novelty flow.
- Never run more than once per day (scraper + WebFetch politeness).
