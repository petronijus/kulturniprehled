# Elektronika expert — Petr's taste profile

Hand-edited taste profile for `/elektronika-expert`. Spotify
electronic library is the primary dynamic source; this file
captures the venue + festival shortlist + hard prefs.

Edit freely — the skill rereads it on every run.

## Hard preferences

- **Veto**: komerční radio-house, EDM festival "drops".
- **Strong yes**: experimentální elektronika, IDM, ambient,
  minimal techno, dub techno, modular, live electronics > DJ sety.

## Genre weights

- experimental / IDM / ambient: 1.0
- techno (minimal, dub): 0.9
- modular / live electronics: 0.9
- house (deep, microhouse): 0.6
- world-electronic fusion: 0.6
- mainstream electronic: 0.2

## Favourite artists / labels

- Aphex Twin
- Autechre
- Plaid
- Squarepusher
- Nicolas Jaar
- Caterina Barbieri
- Suzanne Ciani
- Tim Hecker
- Oneohtrix Point Never
- *(přidávej dle libosti)*

## Active venue / festival WebFetch URLs

The skill hits these via WebFetch in step 4. LLM extracts upcoming
events (next 4 weeks) since these line-ups change frequently.

### Static scrapers (`venues/<name>.sh`, běží před WebFetchem)

- `punctum.sh` — Punctum / Krásovka přes **RSS** (`punctum.cz/rss`, 24 akcí
  s `xcal:dtstart`/`xcal:location`/`xcal:url`). Samotné punctum.cz je Vite
  SPA: **každá cesta vrací týž 5,8kB shell**, takže WebFetch tam od 2026-08
  viděl prázdnou stránku. Diagnóza 2026-09-13, feed je od té doby zdroj.
- `goout.sh <url>` — jedna GoOut stránka. Listingy nesou schema.org
  `application/ld+json`, stránky pořadatelů a klubů `schedule-row` markup.

Primary (club sites — Petrovy kluby, kandidáti odsud jsou vždy fér):

- https://www.palacakropolis.cz — Palác Akropolis
- ~~https://punctum.cz~~ — nahrazeno scraperem `venues/punctum.sh` (viz výše)
- ~~https://lunchmeat.cz~~ — **web je mrtvý** (ověřeno 2026-09-13): apex vrací
  jen splash „Choose your path" bez jediného odkazu, `festival.lunchmeat.cz`
  hlásí WEDOS 503 origin error, `/robots.txt` i `/sitemap.xml` jsou 404. Není
  co scrapovat — není to naše chyba, ale ani to nesmí tiše vracet `[]`.
  Lunchmeat prodává přes GoOut, takže dokud jejich web nenaběhne, jede
  program přes `goout.sh` na jejich pořadatelské stránce.
- https://www.archa-plus.cz/cz/program/ — Archa+ (bývalé Divadlo Archa; správná doména je archa-plus.cz — holé archaplus.cz od 2026-08 servíruje cizí web. Program je WebFetch-readable, detaily mají URL …/program/detail/<id>/<datum>-<slug>)
- https://www.meetfactory.cz/cs/program — MeetFactory <!-- TODO(Petr): verify URL -->

Secondary (aggregator — robust when a club site breaks or a venue has
no programme page; good finds live here, e.g. Basinski @ Gabriel Loci.
Dedup against primary sources by dedup_key):

- https://goout.net/cs/praha/koncerty/ — GoOut, pražské koncerty (přes
  `venues/goout.sh`). **`?tags=electronic` nepoužívat**: filtr se aplikuje
  až v prohlížeči, server vrátí nefiltrovanou stránku, takže dotaz na
  elektroniku z ní právem nic nevytáhne (ověřeno 2026-09-13 — vrátilo to
  post-punk a jazz). Filtrujeme si žánr sami na naší straně.
  Stránky pořadatelů/klubů server-renderují **jen nejbližší termín**, zbytek
  je za „Zobrazit další" — ber je jako „co je nejblíž", ne jako sezónu.

**Venue veto**: Cross Club, Ankali, Roxy (Petr tam nechodí — 2026-08-10).
**Bez výjimek** (2026-08-16): veto je od té doby vynucené i backendem
(`SEASON_VENUE_VETO`) — kandidáta z těchto míst pool odmítne bez ohledu na
interpreta a existující řádky při dalším scrapu smaže. Dřívější výjimka pro
Favourite artists tím padá; kdyby ji Petr chtěl zpátky, musí se změnit obojí.

*(přidávej dle libosti: Lethargy, Sonic Visions, Fuchs2, …)*
