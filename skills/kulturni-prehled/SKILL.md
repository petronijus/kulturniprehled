---
name: kulturni-prehled
description: Weekly culture-aggregator for Petr. Invokes every domain-expert skill (klasika-expert, elektronika-expert, divadlo-expert, film-expert) inline, merges their ranked candidate lists, applies cross-domain rules (balance signal — boost lanes Petr has been neglecting, ~1-event-per-week spacing with `season_event` exceptions, global cap of ~5 picks total), renders one Czech HTML email and sends it via Gmail. **This is the only skill in the suite that sends email.** Designed to be invoked weekly by the /schedule skill.
---

## Task

Compose Petr's weekly culture digest by orchestrating every available
domain expert and sending **one email** with the merged + balanced
top picks. The experts produce raw candidate lists; this skill
applies the cross-cutting rules that turn N×8 candidates into a
single ~5-item curated email.

### 0. Discover experts

```bash
SKILLS_DIR=~/Documents/Dev/kulturniprehled/skills
EXPERTS=$(ls -d "$SKILLS_DIR"/*-expert 2>/dev/null | xargs -n1 basename)
echo "Experts found: $EXPERTS"
```

Today's expected set:

- `klasika-expert`
- `elektronika-expert`

Future:

- `divadlo-expert`
- `film-expert`

This skill needs no edits when a new expert lands — the discovery
loop picks it up automatically.

### 1. Compute the week's digest directory

```bash
WEEK=$(date +%V)
DIGEST_DIR=/tmp/kp-digest-CW${WEEK}
rm -rf "$DIGEST_DIR" && mkdir -p "$DIGEST_DIR"
```

A fresh dir per run guarantees we never serve stale data from a
previous week.

### 2. Invoke each expert (Skill tool, in-process)

For each `<expert>` in `$EXPERTS`, call the `Skill` tool with
`skill: "<expert>"`. The expert runs inline in this Claude session;
it writes its ranked candidates to
`$DIGEST_DIR/<lane>.json` and reports a short summary to chat.

`<lane>` derives from `<expert>` by dropping the `-expert` suffix:
`klasika-expert → klasika.json`, etc.

After each invocation, verify the file landed:

```bash
LANE=${EXPERT%-expert}
[ -s "$DIGEST_DIR/$LANE.json" ] || {
  echo "WARN: $EXPERT did not write $LANE.json — skipping in digest"
}
```

If an expert fails or produces an empty list, log it and continue —
the email still goes out with whatever lanes did succeed.

### 3. Compute balance signal (cross-domain)

```bash
KP_API_BASE="${KP_API_BASE:-https://kulturniprehled.example.com}"
KP_TOKEN="$(op item get 'Kulturni Prehled API Token' --fields label=credential --reveal 2>/dev/null)"
NOW=$(date -Iseconds)
SINCE=$(date -d '6 months ago' -Iseconds)
EVENTS=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  "$KP_API_BASE/v1/events?starts_from=$SINCE&starts_to=$NOW&limit=500")

days_since_cat() {
  local CAT=$1
  local LAST=$(echo "$EVENTS" | jq -r --arg c "$CAT" \
    '[.items[] | select(.category==$c)] | sort_by(.starts_at) | last.starts_at // empty')
  [ -z "$LAST" ] && { echo 999; return; }
  echo $(( ( $(date +%s) - $(date -d "$LAST" +%s) ) / 86400 ))
}
DSC=$(days_since_cat concert)
DST=$(days_since_cat theatre)
DSF=$(days_since_cat cinema)
BALANCE_HINT="${DSC} dní bez koncertu, ${DST} bez divadla, ${DSF} bez kina"
```

Map domain → category, then compute a per-lane **balance multiplier**
that the merge step uses:

| Domain (lane) | Mapped category | Balance multiplier |
|---------------|-----------------|--------------------|
| klasika       | concert         | `1.0 + (DSC - 30) / 60` (clamp 0.5–1.8) |
| elektronika   | concert         | shares DSC with klasika |
| divadlo       | theatre         | `1.0 + (DST - 30) / 60` (clamp 0.5–1.8) |
| film          | cinema          | `1.0 + (DSF - 30) / 60` (clamp 0.5–1.8) |

So if Petr has been to a concert 5 days ago, multiplier ~0.6 (we damp
down further concerts). If 60 days, multiplier ~1.5 (we lean into them).

### 4. Merge + score across lanes

```bash
ALL='[]'
for L in $(ls "$DIGEST_DIR"/*.json 2>/dev/null); do
  LANE_JSON=$(cat "$L")
  LANE_NAME=$(echo "$LANE_JSON" | jq -r '.lane')
  # Apply balance multiplier to each item's score; carry through metadata.
  MULT=$(...compute per the table above...)
  TWEAKED=$(echo "$LANE_JSON" | jq --arg mult "$MULT" --arg lane "$LANE_NAME" '
    .items | map(. + {
      "lane": $lane,
      "label": ($lane | gsub("klasika";"Vážná hudba") | gsub("elektronika";"Elektronika")
                      | gsub("divadlo";"Divadlo") | gsub("film";"Film")),
      "weighted_score": ((.score // 0.5) * ($mult | tonumber))
    })')
  ALL=$(jq -n --argjson a "$ALL" --argjson b "$TWEAKED" '$a + $b')
done
# Sort by weighted score descending
ALL=$(echo "$ALL" | jq 'sort_by(-.weighted_score)')
```

### 4b. Calendar conflict check (Kocourek&Prdelčička)

Petr + Běla share the **Kocourek&Prdelčička** Google Calendar for
vacations, away days, dinner plans, and existing bookings outside KP.
Pull events in the digest horizon and drop / flag conflicting candidates
**before** the spacing rule runs.

```bash
KP_CAL_ID='c_9a5bbccc4605dfbee65ff6ec08e3259596e8fc63bb131db50438b28e9cfece87@group.calendar.google.com'
HORIZON_28D=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(days=28)).isoformat(timespec='seconds'))")
```

List events via the workspace MCP. The shared calendar is only visible
to `petronijus@example.com` — Petr's work address (`petr@example.com`)
doesn't have it on its calendar list. Use the workspace MCP, not the
Google Calendar MCP, because the latter only sees the work account.

```
mcp__workspace-mcp__get_events(
  user_google_email = "petronijus@example.com",
  calendar_id       = KP_CAL_ID,
  time_min          = NOW,
  time_max          = HORIZON_28D,
  max_results       = 100,
  detailed          = true
)
```

For each calendar event, classify:

- **All-day event spanning ≥1 day** → treat every covered date as
  blocked (Petr is on holiday / out of Prague). Candidates with
  `starts_at` falling on any blocked date are dropped from `$ALL`.
- **Timed event** (has `start.dateTime`) → compute overlap with each
  candidate's `starts_at`. If candidate falls within `[event.start − 2h,
  event.end + 1h]` → drop the candidate.
- **Title heuristic** — if the all-day or multi-day event title matches
  `(dovolená|holiday|pryč|away|cottage|šumperák|chalupa)` case-insensitive,
  the date span is treated as blocked even if it lacks the all-day flag.

Edge case: events Petr already booked through KP (concerts/theatre with
tickets) appear here too because `concert-tickets-flow` creates them on
this calendar. Those are also already in the KP API and get caught by
step 6's existing-event exclusion in each expert — double-coverage is
fine, drops are idempotent.

Implementation sketch:

```bash
CAL_EVENTS_JSON='[ ... result of list_events ... ]'
BLOCKED=$(echo "$CAL_EVENTS_JSON" | python3 - <<'PY'
import json, sys, re
from datetime import datetime, timedelta
evs = json.load(sys.stdin)
blocked_days, conflicts = set(), []
vacation_rx = re.compile(r'(dovolen|holiday|pryč|away|cottage|šumperák|chalupa)', re.I)
for e in evs:
    title = (e.get('summary') or '').strip()
    start = e.get('start', {})
    end = e.get('end', {})
    if 'date' in start:                            # all-day
        d0 = datetime.fromisoformat(start['date'])
        d1 = datetime.fromisoformat(end['date'])  # exclusive
        cur = d0
        while cur < d1:
            blocked_days.add(cur.date().isoformat()); cur += timedelta(days=1)
    elif vacation_rx.search(title):                # title-keyed multi-day
        d0 = datetime.fromisoformat(start['dateTime'])
        d1 = datetime.fromisoformat(end['dateTime'])
        cur = d0
        while cur.date() <= d1.date():
            blocked_days.add(cur.date().isoformat()); cur += timedelta(days=1)
    else:                                          # timed conflict
        conflicts.append({
            'start_iso': start.get('dateTime'),
            'end_iso':   end.get('dateTime'),
            'title':     title,
        })
json.dump({'blocked_days': sorted(blocked_days), 'conflicts': conflicts}, sys.stdout)
PY
)

ALL=$(echo "$ALL" | jq --argjson b "$BLOCKED" '
  [ .[] | . as $c |
    ($c.starts_at[0:10]) as $d |
    if ($b.blocked_days | index($d)) then
      empty
    elif (
      $b.conflicts | any(
        ($c.starts_at | fromdateiso8601) as $cs |
        (.start_iso  | fromdateiso8601) as $es |
        (.end_iso    | fromdateiso8601) as $ee |
        ($cs >= $es - 7200) and ($cs <= $ee + 3600)
      )
    ) then
      empty
    else $c end
  ]')
```

Log how many were dropped + the calendar titles that caused it so the
final email's footer can mention it ("Pominul jsem 2 doporučení kvůli
plánům v kalendáři: 'Dovolená Itálie 8–14. 6.'").

### 5. Apply spacing rule (1 event ≈ 1 week)

Build the calendar of already-booked + already-selected events; walk
candidates in score order; accept each if it does **not** clash
(±3 days from an existing pick), unless `season_event: true`.

```bash
HORIZON_PLUS=$(date -d '+60 days' -Iseconds)
BOOKED_DATES=$(curl -sS -A 'kp-skill/1.0' -H "Authorization: Bearer $KP_TOKEN" \
  "$KP_API_BASE/v1/events?starts_from=$NOW&starts_to=$HORIZON_PLUS&limit=200" \
  | jq -r '.items[].starts_at')

SELECTED='[]'
CAP=5                                         # global cap across all lanes

while IFS= read -r ITEM; do
  [ -z "$ITEM" ] && continue
  WHEN=$(echo "$ITEM" | jq -r '.starts_at')
  IS_SEASON=$(echo "$ITEM" | jq -r '.season_event // false')
  # Compute distance in days to nearest booked or already-selected date
  NEAREST=$(printf '%s\n%s\n' "$BOOKED_DATES" "$(echo "$SELECTED" | jq -r '.[].starts_at')" \
    | awk -v t="$(date -d "$WHEN" +%s)" '
      $1 { gsub(/T.*/,"T00:00:00",$1); cmd="date -d \""$1"\" +%s"; cmd | getline ts; close(cmd);
           d = (ts > t) ? ts - t : t - ts; if (d/86400 < min || min == 0) min = d/86400 } END { print int(min) }')
  if [ "$IS_SEASON" = "true" ] || [ -z "$NEAREST" ] || [ "$NEAREST" -ge 6 ]; then
    SELECTED=$(echo "$SELECTED" | jq --argjson it "$ITEM" '. + [$it]')
    [ "$(echo "$SELECTED" | jq 'length')" -ge "$CAP" ] && break
  fi
done < <(echo "$ALL" | jq -c '.[]')
```

(The awk distance helper above is approximate — clean it up if the
spacing logic misbehaves; the simpler / more reliable version is to
compute distances in Python via a one-shot heredoc the same way the
scrapers do.)

### 6. Backfill if pool is too thin

If `$SELECTED` ends up with fewer than 3 items (small pool, every
candidate clashed), relax the spacing rule from ±6 days to ±3 days
and re-run step 5. If still fewer than 3, accept the top 3 regardless
of spacing — better to send a short email than a useless one.

### 7. Render + send the email

```bash
KP_TO=petr@example.com
KP_FROM=petronijus@example.com
SUBJECT="Kulturní přehled — týden CW${WEEK}"
```

HTML template (inline CSS, single-column, mobile-friendly):

```html
<div style="font-family:-apple-system,Segoe UI,sans-serif;color:#111;max-width:600px;margin:0 auto;padding:24px;">
  <h1 style="font-size:20px;margin:0 0 4px;">Kulturní přehled</h1>
  <p style="color:#666;margin:0 0 24px;">Týden CW{{week}} · {{balance_hint}}</p>

  {{#each selected}}
  <div style="border-top:1px solid #eee;padding:18px 0;">
    <p style="margin:0 0 4px;color:#888;font-size:12px;text-transform:uppercase;letter-spacing:0.5px;">
      {{label}}{{#if season_event}} · událost sezóny{{/if}}
    </p>
    <h2 style="font-size:17px;margin:0 0 6px;">{{title}}</h2>
    <p style="margin:0 0 4px;color:#444;font-size:14px;">
      {{date_human}}
      {{#if venue}} · {{venue}}{{/if}}
      {{#if ensemble}} · {{ensemble}}{{/if}}
      {{#if price_czk}} · {{price_czk}} Kč{{/if}}
    </p>
    <p style="margin:8px 0 12px;font-style:italic;color:#222;font-size:14px;">{{why_cs}}</p>
    <a href="{{url}}" style="display:inline-block;padding:8px 14px;background:#111;color:#fff;text-decoration:none;border-radius:6px;font-size:14px;">Detail + lístky →</a>
  </div>
  {{/each}}

  {{#if dropped_count}}
  <p style="color:#999;font-size:12px;margin-top:24px;">
    Z {{total_candidates}} kandidátů jsem vybral {{selected_count}}. {{dropped_count}} jsem zahodil kvůli rozestupu (snažím se o ~1 akci týdně, výjimka pro události sezóny).
  </p>
  {{/if}}
</div>
```

Render inline via string interpolation, then send:

```
mcp__google-workspace__send_gmail_message(
  user_google_email = "petronijus@example.com",
  to = ["petr@example.com"],
  subject = SUBJECT,
  html_body = RENDERED_HTML
)
```

**Real send, not draft.** If the send fails, write the rendered HTML
to `$DIGEST_DIR/_fallback.html` so the run isn't lost.

### 8. Cleanup + report

```bash
# Keep $DIGEST_DIR for one week so debugging stays possible; the next run
# blows it away in step 1.
echo "Odesláno $(echo "$SELECTED" | jq 'length') doporučení."
echo "Lane mix: $(echo "$SELECTED" | jq -r 'group_by(.lane) | map("\(.[0].lane)×\(length)") | join(", ")')"
echo "Balance: $BALANCE_HINT"
```

## When to use

- **Primary**: weekly via `/schedule` (Monday 08:00). This is the
  entry point.
- **Manual**: `/kulturni-prehled` whenever Petr wants a fresh digest
  immediately.

## When NOT to use

- Don't call individual experts directly through this skill — that's
  what the auto-discovery loop is for. Just drop a new
  `skills/<name>-expert/SKILL.md` and the aggregator picks it up.
- Don't run more than once per day — Discogs rate limits + external
  scrapes get cumulatively rude.

## Adding a new expert (e.g. divadlo)

1. Create `skills/divadlo-expert/SKILL.md` following the
   `klasika-expert` template (input gathering, ranking, write
   `$DIGEST_DIR/divadlo.json`, exit). The file must include
   `name: divadlo-expert` in frontmatter.
2. Create `skills/divadlo-expert/preferences.md` for the hand-edited
   profile.
3. Symlink it into `~/.claude/skills/divadlo-expert`.
4. No changes to this aggregator needed. It auto-discovers via the
   `skills/*-expert` glob.
