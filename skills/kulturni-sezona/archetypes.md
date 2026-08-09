# Season scenario archetypes

Hand-editable briefs for the ~5 scenarios the `kulturni-sezona` orchestrator
generates. Each brief guides the LLM's selection; the hard rules (week cap,
gaps, blocked days, work dedup, price) are enforced separately by
`bin/kp_validate.py` and are NOT restated here.

Shared ground rules for every archetype:

- Target size: **25–35 events** across the season (Sep–Jun) plus reserved
  slots for sparse lanes. That is ~1 event/week with breathing room — never
  plan the calendar full; novelties keep arriving all season.
- Sparse lanes (elektronika, film — clubs and cinemas announce 1–2 months
  ahead) get **`reserved_slots`** (`{lane, month, note_cs}`), not invented
  events. Never fabricate an event to fill a month.
- 1–2 `season_event: true` picks may sit close to other events (the gap
  exemption), but the week cap is sacred.
- Era variety is dramaturgy, not a quota: look at what the year already
  contains (history in `context.json`) and lean against the dominant era —
  a Romantic-heavy year wants a Reich/Bach/Xenakis counterweight.
- Every event carries a specific Czech `why_cs` (composer/work first,
  Discogs connection where real); every scenario carries a one-line Czech
  `motto_cs` shown in the SPA tab tooltip.

## velka-symfonika — „Velká symfonika"

The orchestral spine: 12–15 big symphonic nights (ČF, FOK, SOČR, hosting
orchestras; Mahler–Bruckner–Shostakovich–Dvořák axis), divadlo/film as a
monthly counterweight, elektronika ~1 reserved slot per quarter. Higher
price tolerance within the clamp — this is the year Petr splurges on the
Rudolfinum. Motto sketch: „Rok velkých orchestrů."

## objevy-a-soudoba — „Objevy a soudobá"

Orchestr Berg, Klangsystematiek, contemporary premieres, Studio Hrdinů /
PONEC experimental theatre and dance, live-electronics-leaning elektronika
slots, artfilm/festival cinema. Deliberately minimal overlap with
velka-symfonika — if a pick would fit both, it belongs there, not here.
Motto sketch: „Sezóna objevů — co jsi ještě neslyšel."

## festivalovy-rok — „Festivalový rok"

Anchored on festival blocks: Dvořákova Praha (září), Struny podzimu /
Prague Sounds (listopad), Pražské jaro (květen–červen), Febiofest, Das
Filmfest. Generous use of `season_event` inside festival weeks, deliberately
sparse in between so festival weeks don't blow the cap. Motto sketch:
„Od festivalu k festivalu."

## komorni-sezona — „Komorní sezóna"

Chamber music, recitals, small stages (Dejvické, Na zábradlí), cinema
d'auteur; the low-price, low-fatigue steady year — nothing over the price
warning band, ~1 event/week like clockwork. Motto sketch: „Malé sály,
velká intimita."

## vyvazeny-mix — „Vyvážený mix"

The default recommendation. Explicit lane balance target: ~40 % klasika,
~25 % divadlo, ~20 % film + elektronika (mostly via reserved slots),
~15 % wildcards from any lane. Month-level variety is a first-class goal —
no month should read as a single genre. Motto sketch: „Ode všeho to
nejlepší."
