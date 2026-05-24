# Klasika expert — Petr's taste profile

Hand-edited taste profile for `/klasika-expert`. Spotify + Discogs
feed dynamic data; this file captures vetoes, weightings, and the
shortlist of ensembles + festivals that drive the static + dynamic
candidate-gathering steps.

Edit freely — the skill rereads it on every run.

## Hard preferences

- **Veto**: dechovky, lidovka, muzikály (s velmi vzácnou výjimkou —
  pokud je to klasika jako *West Side Story* s reálným orchestrem,
  budiž; ABBA tribute NE).
- **Strong yes**: klasika (baroko → 20. století — Bach, Beethoven,
  Mahler, Šostakovič, Bartók, Ligeti), soudobá vážná, jazz s
  klasickým přesahem (Mehldau, Hamasyan), world music s reálným
  zázemím.

## Genre weights

Multiplikátor v rankingu. 1.0 = "normální zájem", 0.5 = "občas",
0.0 = "ne".

- klasika symfonická: 1.0
- klasika komorní: 1.0
- klasika vokální (oratoria, písňové cykly): 0.9
- soudobá vážná: 0.9
- baroko / staré: 0.8
- jazz s klasickým přesahem: 0.7
- world / etno: 0.4

## Favourite ensembles

Free-form list. Match against candidate titles + artist fields. The
skill biases recommendations toward anything that overlaps.

- Česká filharmonie
- PKF – Prague Philharmonia
- FOK – Symfonický orchestr hl. m. Prahy
- SOČR – Symfonický orchestr Českého rozhlasu
- Orchestr Berg (kontemporární)
- Vienna Philharmonic (host)
- Berlin Philharmonic (host)
- *(přidávej dle libosti)*

## Favourite soloists (extra ranking bias)

- Anouar Brahem
- Tigran Hamasyan
- Brad Mehldau
- Vijay Iyer
- Anoushka Shankar
- Hilary Hahn
- Patricia Kopatchinskaja
- Lisa Batiashvili
- *(přidávej dle libosti)*

### Active ensemble scrapers

Names of `ensembles/<name>.sh` the skill runs in step 5a.

- ceska-filharmonie
- fok
- pkf
- socr
- berg

### Active festival WebFetch URLs

The skill hits these in step 5b. LLM extracts upcoming events.

- https://www.festival.cz/program/ — Pražské jaro
- https://www.strunypodzimu.cz/cs/program — Struny podzimu
- https://www.dvorakovapraha.cz/program — Dvořákova Praha
- *(přidávej dle libosti)*

## Price awareness

Cena je soft deflator atraktivity. Vyprodáno **není** veto — hlídací pes
někdy uvolní místa.

Petr nikdy nekupuje VIP / lóže / box / sponzor lístky, hledá primárně
parter. Velké koncerty na velkých venues (Obecní dům, Forum Karlín)
prodávají horní tier 4 000–8 000 Kč, který skill **nesmí** brát jako
směrodatný. Algoritmus: pokud horní hranice rozsahu je více než 5× vyšší
než dolní, ořezat ji na `dolní × 4` před výpočtem midpointu (viz SKILL.md
step 7 "Price deflator"). Příklad: Rotterdam 900–8 000 → clamp na
900–3 600 → midpoint 2 250 Kč ("drahé"), ne 4 450 Kč (vyřazeno).

| Cena (midpoint po VIP-clampu, Kč) | Deflator | Poznámka |
|---|---|---|
| < 1 000 | 0.00 | komfortní zóna |
| 1 000 – 2 000 | −0.05 | mírně dražší |
| 2 000 – 3 000 | −0.15 | drahé, jen u silně preferovaných composer-matchů |
| > 3 000 | vyřazeno |

Pravidla pro `tickets_available: false`:
- ponechat v poolu, score neměnit
- v `why_cs` přidat na začátek `⚠ Lístky momentálně vyprodány — můžeš zkusit hlídacího psa.`

## Discogs username

petronijus
