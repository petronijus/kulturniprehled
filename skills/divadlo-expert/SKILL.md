---
name: divadlo-expert
description: Domain-expert agent for divadlo (činohra, experimentální scéna, tanec, opera-as-theatre). Pulls Petr's hand-edited preferences, hits Prague theatre programme URLs via WebFetch, and produces a ranked top-N list of candidates as structured JSON. **Sends no email — output is consumed by the kulturni-prehled novelty watcher and the kulturni-sezona orchestrator.** Can also be invoked directly for a divadlo snapshot in chat. DISABLED in active-experts.txt until preferences.md TODOs are filled.
---

## Task

Build a ranked list of upcoming **divadlo** events Petr should consider.
Write the result as JSON to a known location; **never send email**.

## Modes

Same `args` convention as klasika-expert
(`Skill(skill: "divadlo-expert", args: "mode=season season=2026-27")`;
no args → `weekly`).

| | `weekly` (default) | `season` |
|---|---|---|
| Candidate window | rolling 90 days (theatres publish ahead, but premieres land continuously) | fixed season Sep 1 – Jun 30 — theatres publish full seasons, expect deep coverage |
| Output file | `/tmp/kp-digest-CW<n>/divadlo.json` | `/tmp/kp-season-<season>/divadlo.json` |
| Candidate count | 8–12 | 20–40, no trimming |

### 0. Output contract — write this file at the end

Same envelope as `klasika.json` (`{lane, label, generated_at,
missing_sources, items}`), with:

- `lane`: `"divadlo"`, `label`: `"Divadlo"`
- `program`: `[{author, play}]` — the theatre analog of composer/work.
  The caller's work-dedup treats `author|play` exactly like
  `composer|work`.
- `detail`: `{director, production, stage}` — **dedup is per
  production**, not per play: the same Hamlet in a different staging is
  fresh material; a repertoire re-run of the same production Petr saw is
  not.
- Multi-date repertoire productions sell per date — `tickets_available`
  must reflect the specific date (klasika's opera rule). Emit ONE
  candidate per sensible date (the best-fitting weekday), not one per
  every repertoire date; mention alternative dates in `why_cs`.
- 1–2 `season_event: true` for genuine one-offs (hosting company visit,
  premiere of a director Petr follows, derniéra).

### 1. Resolve KP API base + bearer token

Identical to `klasika-expert/SKILL.md` step 1 (op → .env fallback,
`-A 'kp-skill/1.0'` for every curl).

### 2. Load preferences

```bash
SKILL_DIR=~/Documents/Dev/kulturniprehled/skills/divadlo-expert
PREFS=$(cat "$SKILL_DIR/preferences.md")
WEBFETCH_URLS=$(grep -A40 'Active theatre WebFetch URLs' "$SKILL_DIR/preferences.md" \
  | sed -n 's/^- *\(https\?:\/\/[^ ]\+\).*/\1/p')
```

(No static scrapers — theatre sites are template-heavy and change often;
WebFetch-only like elektronika.)

### 3. Gather candidates via WebFetch

For each URL, WebFetch with:

> "List every upcoming theatre / dance / performance event on this page
> between {NOW} and {WINDOW_TO}, as a JSON array. Each item: `title`,
> `starts_at` (ISO 8601), `venue`, `url` (absolute), `price_czk` if
> mentioned, `author` and `director` if visible. One item per
> production; prefer the earliest date with tickets available and list
> other dates in `alt_dates`. Skip past events. Output JSON only."

### 4. Enrich top candidates

Check the backend season pool first and skip already-enriched
candidates exactly as `klasika-expert/SKILL.md` step 5d does (same
`dedup_key` recipe, same `GET /v1/season/plans/current` + pool query).
Cap fresh detail fetches at top 40 (season) / 20 (weekly). Extract
`{program: [{author, play}], director, production, price_czk,
tickets_available}` from the detail page.

### 5. Exclude already-booked

As `klasika-expert/SKILL.md` step 6, with `category=theatre`. History
dedup: same **production** this season = hard veto; same play in a
different production = fine, mention the comparison in `why_cs`.

### 6. Rank (LLM step — you are the LLM)

Reason over `$PREFS` (vetoes, genre weights, favourite stages/directors)
+ candidates + history. Czech `why_cs` leads with author + play, then
the specific connection (director, stage, ensemble). Apply the price
posture from preferences.

### 7. Write output JSON + report

As klasika steps 8–9, with the mode's output path and a one-line Czech
summary.

## When to use / NOT to use

- Weekly via the novelty watcher, seasonally via the orchestrator, or
  directly as `/divadlo-expert`.
- Not more than once a day; never send email.
