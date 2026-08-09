---
name: kulturni-prehled
description: Weekly novelty watcher for Petr's season plan. Runs every active domain-expert skill in weekly mode, diffs the scrape against the backend season pool, pushes pool updates, and emails ONLY newly announced events with a fit-suggestion against the standing plan (kp_validate.py fit). Also watches ticket availability on planned events. **This is the only skill in the suite that sends email.** Designed to be invoked weekly by the /schedule skill; season planning itself lives in /kulturni-sezona.
---

## Task

Petr's season plan lives in the backend (built by `/kulturni-sezona`,
finalized in the SPA at `/app`). This weekly run answers one question:
**what got announced since last week, and where would it fit?** It never
re-recommends the existing pool — the plan is Petr's, the watcher only
brings news.

### API contract (single edit point)

- `GET  /v1/season/plans/current` → `{id, label, novelty_ack_at, …}`; 404 = no season
- `GET  /v1/season/plans/{id}/pool?limit=1000&offset=N` → full pool (dedup keys + enrichment + plan_status)
- `GET  /v1/season/plans/{id}/plan` → `{selected[], counts, weeks}`
- `GET  /v1/season/plans/{id}/scenarios` → for the applied scenario's `reserved_slots`
- `PUT  /v1/season/plans/{id}/pool` → idempotent upsert `{created, updated, unchanged}`
- `GET  /v1/season/plans/{id}/novelties` → candidates first seen after `novelty_ack_at`
- `POST /v1/season/plans/{id}/novelties/ack` `{through}` → advance the cursor (only after a successful send!)
- `GET  /v1/digest/context` → balance hint + feedback sentiment + booked[]
- `dedup_key` recipe: canonical definition in `skills/kulturni-sezona/SKILL.md`

### 0. Discover experts

```bash
SKILLS_DIR=~/Documents/Dev/kulturniprehled/skills
AGGREGATOR_DIR="$SKILLS_DIR/kulturni-prehled"
EXPERTS=$(grep -v '^#' "$AGGREGATOR_DIR/active-experts.txt" 2>/dev/null \
  | sed '/^$/d' | tr '\n' ' ')
echo "Active experts: $EXPERTS"
```

One expert per line; `#` comments ignored. To enable a new expert, add
its name — no aggregator changes needed.

### 1. Resolve auth + season + week dir

```bash
KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.example.com}"
KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --fields label=credential --reveal 2>/dev/null)"
WEEK=$(date +%V)
DIGEST_DIR=/tmp/kp-digest-CW${WEEK}
rm -rf "$DIGEST_DIR" && mkdir -p "$DIGEST_DIR"

SEASON=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  "$KP_API_BASE/v1/season/plans/current")
SEASON_UUID=$(printf '%s' "$SEASON" | jq -r '.id // empty')
```

**No active season → stop.** Print „Žádná aktivní sezóna — spusť
`/kulturni-sezona`" and exit; do not email.

### 2. Assemble context

Into `$DIGEST_DIR`:

- `pool.json` ← page through `GET …/pool?limit=1000` (all statuses).
- `plan.json` ← `GET …/plan`, then attach `reserved_slots` from the
  applied scenario (`GET …/scenarios`, pick `applied_scenario_id` from
  the plan response; fall back to rank 1 if none applied yet).
- `context.json` ← `GET /v1/digest/context?horizon_days=180&lookback_days=180`
  (`booked`, `feedback.lane_sentiment`, `feedback.recent_downvoted_titles`,
  `balance.hint` for the email footer).
- `blocked.json` ← the shared **Kocourek&Prdelčička** calendar
  (`c_9a5bbccc4605dfbee65ff6ec08e3259596e8fc63bb131db50438b28e9cfece87@group.calendar.google.com`)
  over the next 180 days via the workspace MCP
  (`mcp__workspace-mcp__get_events`, `user_google_email`
  `petronijus@example.com` — the work account cannot see this calendar).
  Classify: all-day events → every covered date into `blocked_days`;
  multi-day titles matching
  `(dovolená|holiday|pryč|away|cottage|šumperák|chalupa)` (case-insensitive)
  likewise; timed events → `conflicts` `{start_iso, end_iso, title}`.
  Calendar unavailable → empty `blocked.json` + a footer note in the email.

### 3. Run experts (weekly mode)

For each expert, call the `Skill` tool with `skill: "<expert>"` (no
args — weekly is the default). Each writes
`$DIGEST_DIR/<lane>.json`; missing/empty file → warn and continue.
Experts do pool-aware enrichment themselves (they skip WebFetch detail
for already-enriched dedup keys), so a weekly run is cheap.

### 4. Diff against the pool

```bash
POOL_KEYS=$(jq -r '.[].dedup_key' "$DIGEST_DIR/pool.json" | sort -u)
```

Compute `dedup_key` for every scraped candidate (recipe in
`kulturni-sezona/SKILL.md`). Split:

- **Novelties** — keys not in `$POOL_KEYS`.
- **Updates** — keys already present; interesting only for the
  **ticket watchdog**: a pool candidate with `plan_status == "selected"`
  and `tickets_available == false` whose fresh scrape says `true`
  becomes a „lístky se uvolnily" line in the email.

Enrich novelties that still lack `program` (cap ~15 per lane), then
**push the entire scraped set** via `PUT …/pool` in chunks of ~100 —
content hashing makes unchanged rows free, `last_seen_at` stays fresh,
and this is what grows elektronika/film coverage all season. User-owned
plan fields are never touched by the upsert.

### 5. Score + fit-check novelties

Per novelty:

1. Expert score × feedback dampening: title in
   `recent_downvoted_titles` → ×0.2; lane sentiment multiplier from
   `feedback.lane_sentiment`.
2. Drop below 0.6.
3. Fit check:

```bash
python3 "$SKILLS_DIR/kulturni-sezona/bin/kp_validate.py" fit \
  --candidate "$DIGEST_DIR/novelty-<key>.json" \
  --plan "$DIGEST_DIR/plan.json" \
  --context "$DIGEST_DIR/context.json" \
  --blocked "$DIGEST_DIR/blocked.json" > "$DIGEST_DIR/fit-<key>.json"
```

`{fits, week, fills_reserved_slot, reasons_cs}` drives the email line:

- fits + fills a reserved slot → „🧩 Zaplní rezervované místo v plánu:
  elektronika, listopad."
- fits → „✅ Sedlo by do týdne {week} (volný)."
- doesn't fit → „⛔ Nesedí — {reasons_cs}." If the production has other
  dates (`alt_dates` from the expert), check the best alternative and
  mention it: „…; alternativní termín {date} volný."

### 6. Compose the email — novelties only

**Zero fitting novelties and zero watchdog lines → no email.** Print
„Žádné novinky tento týden" to the run log and still ack (step 8).

Selection: top ~5 fitting novelties (across lanes, by damped score) +
up to 3 notable non-fitting (score ≥ 0.70) as „Notable mentions" with
their `drop_reason` = fit reasons. Ticket-watchdog lines go in a short
section above the footer.

#### Feedback tokens

For each emailed item, HMAC-signed 👍/👎 links. The secret must match
production `API_JWT_SECRET`:

```bash
KP_JWT_SECRET="$(ssh petronijus@192.0.2.101 'grep ^API_JWT_SECRET= /opt/kp/.env' | cut -d= -f2)"
[ -n "$KP_JWT_SECRET" ] || echo "WARN: no prod JWT secret, feedback links disabled"
```

```python
import hashlib, hmac, json
from base64 import urlsafe_b64encode

def make_token(title, lane, week, rating, secret):
    payload = json.dumps({"t": title, "l": lane, "w": week, "r": rating},
                         ensure_ascii=False, separators=(",", ":")).encode()
    sig = hmac.new(secret.encode(), payload, hashlib.sha256).digest()[:16]
    return urlsafe_b64encode(payload + sig).rstrip(b"=").decode()
# url_up  = f"{KP_API_BASE}/v1/feedback/rate?t={make_token(..., 'up', secret)}"
# url_down = f"{KP_API_BASE}/v1/feedback/rate?t={make_token(..., 'down', secret)}"
```

#### Template

```bash
KP_TO=petronijus@example.com
SUBJECT="Kulturní přehled — novinky, týden CW${WEEK}"
```

```html
<div style="font-family:-apple-system,Segoe UI,sans-serif;color:#111;max-width:600px;margin:0 auto;padding:24px;">
  <h1 style="font-size:20px;margin:0 0 4px;">Kulturní přehled — novinky</h1>
  <p style="color:#666;margin:0 0 24px;">Týden CW{{week}} · nové akce od minulého týdne · {{balance_hint}}</p>

  {{#each novelties}}
  <div style="border-top:1px solid #eee;padding:18px 0;">
    <p style="margin:0 0 4px;color:#888;font-size:12px;text-transform:uppercase;letter-spacing:0.5px;">
      {{label}}{{#if season_event}} · událost sezóny{{/if}} · NOVÉ
    </p>
    <h2 style="font-size:17px;margin:0 0 6px;">{{title}}</h2>
    {{#if source_name}}
    <span style="display:inline-block;margin:0 0 6px;padding:2px 8px 2px 4px;border-radius:4px;font-size:11px;font-weight:600;letter-spacing:0.3px;
      {{#if (eq source_type 'festival')}}background:#FFF3E0;color:#E65100;{{/if}}
      {{#if (eq source_type 'sezona')}}background:#F5F5F5;color:#616161;{{/if}}
      {{#if (eq source_type 'objev')}}background:#E8F5E9;color:#2E7D32;{{/if}}
    ">{{#if source_logo_url}}<img src="{{source_logo_url}}" width="16" height="16" alt="" style="vertical-align:-4px;border-radius:3px;margin-right:4px">{{/if}}{{source_name}}</span>
    {{/if}}
    <p style="margin:0 0 4px;color:#444;font-size:14px;">
      {{date_human}}{{#if venue}} · {{venue}}{{/if}}{{#if price_czk}} · {{price_czk}} Kč{{/if}}
    </p>
    <p style="margin:6px 0;font-size:13px;">{{fit_line}}</p>
    <p style="margin:8px 0 12px;font-style:italic;color:#222;font-size:14px;">{{why_cs}}</p>
    <div style="display:flex;align-items:center;gap:12px;margin-top:8px;">
      <a href="{{url}}" style="display:inline-block;padding:8px 14px;background:#111;color:#fff;text-decoration:none;border-radius:6px;font-size:14px;">Detail + lístky →</a>
      <a href="{{url_up}}" style="text-decoration:none;font-size:22px;" title="Líbí se">👍</a>
      <a href="{{url_down}}" style="text-decoration:none;font-size:22px;" title="Nelíbí se">👎</a>
    </div>
  </div>
  {{/each}}

  {{#if watchdog}}
  <div style="border-top:2px solid #eee;margin-top:28px;padding-top:18px;">
    <p style="margin:0 0 12px;color:#888;font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px;">Hlídací pes</p>
    {{#each watchdog}}
    <p style="margin:0 0 8px;font-size:13px;color:#444;">🎟 <strong>{{title}}</strong> — lístky se uvolnily. <a href="{{url}}">Koupit →</a></p>
    {{/each}}
  </div>
  {{/if}}

  {{#if notable_mentions}}
  <div style="border-top:2px solid #eee;margin-top:28px;padding-top:18px;">
    <p style="margin:0 0 12px;color:#888;font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px;">Notable mentions</p>
    <p style="margin:0 0 12px;color:#999;font-size:12px;">Zajímavé novinky, co se do plánu nevešly:</p>
    {{#each notable_mentions}}
    <p style="margin:0 0 8px;font-size:13px;color:#444;">
      <a href="{{url}}" style="color:#111;text-decoration:underline;"><strong>{{title}}</strong></a> · {{date_human}}
      <br><span style="color:#888;font-size:12px;">{{drop_reason}}</span>
    </p>
    {{/each}}
  </div>
  {{/if}}

  <p style="color:#999;font-size:12px;margin-top:24px;">
    {{novelty_total}} novinek tento týden, {{pushed_count}} přidáno do poolu.
    Plán upravíš na {{app_url}}.
  </p>
</div>
```

`date_human` computed programmatically (Czech weekday map, never
guessed) as in `klasika-expert/SKILL.md` step 0.

**Source logos** (`source_logo_url`): official ensemble/festival logos
live in the public MinIO bucket —
`https://kulturniprehled-tickets.example.com/event-images/logos/<slug>.png`
where `<slug>` = `source_name` lowercased, diacritics stripped,
non-alphanumerics collapsed to single dashes (e.g. "Česká filharmonie"
→ `ceska-filharmonie`, "PKF – Prague Philharmonia" → `pkf`). The
frontend's canonical slug map is
`apps/api/web/src/domain/sources.ts` — if the slug is not in that map,
omit the `<img>` (aggregator sources like Songkick/GoOut have no logo
on purpose). New logos: drop a PNG into `apps/api/web/public/logos/`
AND `mc cp` it to the bucket so web + e-mail stay in sync.

Send via the workspace MCP (real send, not draft):

```
mcp__google-workspace__send_gmail_message(
  user_google_email = "petronijus@example.com",
  to = ["petronijus@example.com"],
  subject = SUBJECT, html_body = RENDERED_HTML)
```

On failure write `$DIGEST_DIR/_fallback.html` and DO NOT ack.

### 7. Ack the novelty cursor

Only after a successful send (or a legitimate zero-novelty week):

```bash
NOW_ISO=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())")
curl -sS -A 'kp-skill/1.0' -X POST -H "Authorization: Bearer $KP_TOKEN" \
  -H 'Content-Type: application/json' -d "{\"through\": \"$NOW_ISO\"}" \
  "$KP_API_BASE/v1/season/plans/$SEASON_UUID/novelties/ack"
```

A failed send leaves the cursor untouched, so the same novelties
resurface next Saturday.

### 8. Report

```bash
echo "Novinky: <n> (posláno <m>, notable <k>), pool +<created>/~<updated>."
echo "Watchdog: <w> uvolněných lístků. Balance: $BALANCE_HINT"
```

## When to use

- **Primary**: weekly via `/schedule` (Saturday 11:00).
- **Manual**: `/kulturni-prehled` for an immediate novelty check.

## When NOT to use

- Season planning / scenario generation → `/kulturni-sezona`.
- Don't run more than once per day (external scrape politeness), and
  never bypass the ack discipline — double-send is worse than late.
