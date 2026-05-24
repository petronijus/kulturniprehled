# `kulturni-prehled` — operator notes

Weekly culture-aggregator skill. Mirrors the name of the app on
purpose — *Kulturní Přehled* the agent feeds *Kulturní Přehled* the
app, by emailing Petr the curated short-list every Monday morning so
he can buy tickets at his desk.

The aggregator is the **only skill in the suite that sends email**.
Domain experts (`klasika-expert`, `elektronika-expert`, eventually
`divadlo-expert` + `film-expert`) produce ranked candidate JSON; the
aggregator merges, balances, applies the 1-event-per-week spacing
rule, and renders the single email.

The mechanics are in [`SKILL.md`](./SKILL.md). This file covers the
**one-time operator steps** that aren't part of the skill itself.

## Architecture at a glance

```
/schedule (Mon 08:00) ─→ /kulturni-prehled (aggregator)
                            │
                            ├─→ Skill /klasika-expert     → /tmp/kp-digest-CW<n>/klasika.json
                            ├─→ Skill /elektronika-expert → /tmp/kp-digest-CW<n>/elektronika.json
                            ├─→ Skill /divadlo-expert     → divadlo.json   (future)
                            └─→ Skill /film-expert        → film.json      (future)
                                              │
                                              ▼
                            merge + balance + spacing + send Gmail
```

Cross-domain rules the aggregator owns (and the experts deliberately
don't):

- **Balance signal** — pull last-event-per-category from the KP API,
  compute days-since-X, boost lanes that have been neglected.
- **Spacing** — ideal cadence ≈ 1 cultural event per week. Walk
  candidates in score order; reject anything within ±3 days of an
  already-booked or already-selected event. **Exception**:
  `season_event: true` (set by the expert) always passes.
- **Global cap** — at most 5 picks across all lanes per week.
- **Backfill** — if spacing leaves us with <3, relax to ±1 day; if
  still <3, accept top 3 regardless of spacing.

## Folder layout

```
skills/kulturni-prehled/
├── SKILL.md          # aggregator orchestration
└── README.md         # this file

skills/klasika-expert/
├── SKILL.md
├── preferences.md
└── ensembles/        # static scrapers
    ├── ceska-filharmonie.sh
    ├── fok.sh
    ├── pkf.sh
    ├── socr.sh
    └── berg.sh

skills/elektronika-expert/
├── SKILL.md
└── preferences.md
```

Each `*-expert` skill is fully usable standalone (`/klasika-expert`
in chat returns ranked JSON without sending anything), and is also
called by the aggregator in scheduled runs.

## One-time setup

### 1. Symlink all four skills into `~/.claude/skills/` (once per machine)

```bash
cd ~/Documents/Dev/kulturniprehled
for S in kulturni-prehled klasika-expert elektronika-expert; do
  ln -sfn "$(pwd)/skills/$S" ~/.claude/skills/$S
done
```

Re-run after `git pull` is a no-op.

### 2. Create the Discogs API key (once)

The klasika expert augments its taste profile with the user's Discogs
collection. 1Password item `Discogs API key`, field `credential`.

1. <https://www.discogs.com/settings/developers> → Generate new token.
2. Pipe straight into 1Password — never echo:
   ```bash
   read -rs TOK && op item create --category="API Credential" --title='Discogs API key' \
     --vault=API credential="$TOK" && unset TOK
   ```
3. Confirm Discogs username (top-right → Profile). Edit
   `skills/klasika-expert/preferences.md` → `## Discogs username`
   if it's not `petronijus`.

Skip and the klasika expert still runs but flags `MISSING_DISCOGS`.

### 3. Mint a Kulturní Přehled PAT (once, if not already present)

```bash
./scripts/mint-pat.sh petr@example.com 'kulturni-prehled'
# wrapper writes the token straight into 1Password
```

Skip if `op item list | grep -i 'Kulturni Prehled API Token'` already
shows the item.

### 4. Wire up `/schedule`

In a Claude Code session run `/schedule`:

- **Name**: `kulturni-prehled`
- **When**: Monday 08:00 Europe/Prague (cron: `0 8 * * 1`)
- **Task**: `/kulturni-prehled`

The aggregator picks up the experts automatically — no need to
schedule them individually.

## Day-to-day operator life

### "I'd like the digest right now"

`/kulturni-prehled` in any Claude Code session. ~2–3 min, then check
inbox.

### "I just want to see what the klasika expert thinks, no email"

`/klasika-expert` (or `/elektronika-expert`) directly. Returns the
ranked JSON in chat; nothing leaves the machine.

### "The picks are too clustered / too sparse"

Edit `skills/kulturni-prehled/SKILL.md` step 5 — the spacing window
(±3 days) and global cap (5) are constants. Adjust to taste.

### "A specific lane keeps recommending stuff I'd skip"

Edit the expert's `preferences.md`. The aggregator never sees the
expert's reasoning — only the ranked JSON output — so all tuning
happens at the expert level.

### "I bought a ticket — make sure the aggregator doesn't keep suggesting it"

You don't need to do anything. Every expert filters against already-
booked events (queried from the KP API). Once
`kulturni-prehled-ingest` registers the new event the aggregator
silently drops it from future digests.

## Why this shape

Why split experts from aggregator?

1. **Domain depth** — a klasika expert can reason richly about
   Mahler symphonies and Czech philharmonic conductors; an
   elektronika expert about Warp Records' roster and live-modular
   scene specifics. One mega-prompt mixing all of that loses focus.
2. **Single email constraint** — Petr wants one email per week, not
   four. The aggregator is the only place that knows about *all*
   lanes' candidates at once, so it's the right place to enforce
   spacing.
3. **Independent operability** — Petr can call any expert directly
   when he wants a snapshot in chat without spamming his inbox.
4. **Trivial to add lanes** — drop a new `skills/<x>-expert/`, the
   aggregator auto-discovers it. Zero changes to existing files.

## Follow-ups

- `divadlo-expert` — Národní divadlo, Divadlo Husa na provázku,
  Studio Hrdinů, festivals (Příští vlna, Divadlo Plzeň).
- `film-expert` — Aero, Lucerna, Světozor, Kino 35; periodical RSS
  scrape (A2, Aktuálně Film, Full Moon).
- Feedback loop: track "I bought / skipped" so future runs learn.
  Probably overkill for two users — wait until it actually feels
  needed.
