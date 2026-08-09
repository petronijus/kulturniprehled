---
name: film-expert
description: Domain-expert agent for film (artová kina, festivalové ozvěny, projekce s doprovodem). Pulls Petr's hand-edited preferences, hits Prague cinema programme URLs via WebFetch, and produces a ranked top-N list of candidates as structured JSON. **Sends no email — output is consumed by the kulturni-prehled novelty watcher and the kulturni-sezona orchestrator.** Can also be invoked directly for a film snapshot in chat. DISABLED in active-experts.txt until preferences.md TODOs are filled.
---

## Task

Build a ranked list of upcoming **film** events Petr should consider.
Write the result as JSON to a known location; **never send email**.

## Modes

Same `args` convention as klasika-expert
(`Skill(skill: "film-expert", args: "mode=season season=2026-27")`;
no args → `weekly`).

**Horizon caveat.** Cinemas publish 2–4 weeks ahead; only festivals
announce further out. Season mode scrapes the same ~30-day window plus
festival pages, writes to `/tmp/kp-season-<season>/film.json` and adds
`"coverage": "partial"` to the envelope — the orchestrator turns
uncovered months into `reserved_slots`. Never invent screenings.

### 0. Output contract — write this file at the end

```
weekly: /tmp/kp-digest-CW<n>/film.json
season: /tmp/kp-season-<season>/film.json   (+ "coverage": "partial")
```

Same envelope as `klasika.json`, with:

- `lane`: `"film"`, `label`: `"Film"`
- `program`: `[{director, film}]`; `detail`: `{year, cycle}` (e.g.
  a retrospective cycle name). Work-dedup key is `director|film` —
  the same film in the same year is a repeat, a different restoration
  years later is fresh.
- Prefer **event screenings** over regular distribution: premieres with
  delegation, restored classics, silent film with live music, festival
  echoes, retrospectives. A film in normal distribution runs for weeks —
  only include it when there is a reason THIS screening matters, and
  say so in `why_cs`.
- 1–2 `season_event: true` for one-offs (35mm print, director Q&A).

### 1.–2. Auth + preferences

As `divadlo-expert` steps 1–2, with section header
`Active cinema WebFetch URLs`.

### 3. Gather candidates via WebFetch

> "List every notable upcoming screening on this page between {NOW} and
> {WINDOW_TO} as a JSON array — premieres, one-off events, retrospectives,
> festival screenings; skip regular repertoire repeats. Each item:
> `title`, `starts_at` (ISO 8601), `venue`, `url`, `price_czk`,
> `director` and `year` if visible. Output JSON only."

### 4.–5. Enrich + exclude booked

Pool-aware enrichment as `klasika-expert` step 5d (cap 20); booked
exclusion with `category=cinema`; history dedup per `director|film`
within the year.

### 6.–7. Rank + write + report

As divadlo-expert: preferences-driven LLM ranking, Czech `why_cs`
leading with director + film, mode-dependent output path, one-line
report. Candidate count: 8–12 weekly, everything above threshold in
season mode.

## When to use / NOT to use

- Weekly via the novelty watcher, seasonally via the orchestrator, or
  directly as `/film-expert`.
- Not more than once a day; never send email.
