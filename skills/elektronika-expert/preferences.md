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

Primary (club sites — Petrovy kluby, kandidáti odsud jsou vždy fér):

- https://www.palacakropolis.cz — Palác Akropolis
- https://punctum.cz — Punctum / Krásovka <!-- TODO(Petr): verify URL — returned an empty page 2026-08 -->
- https://lunchmeat.cz — Lunchmeat (festival + jednorázovky)
- https://archaplus.cz/program/ — Archa+ <!-- TODO(Petr): verify URL (bývalé Divadlo Archa) -->
- https://www.meetfactory.cz/cs/program — MeetFactory <!-- TODO(Petr): verify URL -->

Secondary (aggregators — Resident Advisor, GoOut, Songkick). **STRICT
RULE**: aggregators serve (a) date/availability verification and
(b) catching favourite-artist shows at venues without their own
programme page (Basinski @ Gabriel Loci). A candidate sourced ONLY from
an aggregator must match `## Favourite artists / labels` or score ≥ 0.7
on genre fit — venue-only discoveries are noise, never emit them.

- https://ra.co/events/cz/prague — Resident Advisor Praha (403 for curl; try WebFetch)
- https://goout.net/cs/praha/koncerty/?tags=electronic — GoOut elektronika

**Venue veto**: Cross Club, Ankali, Roxy (Petr tam nechodí — 2026-08-10).
Favourite-artist exception applies i tady: kdyby v Ankali hrál někdo
z Favourite artists, smí projít — samotné venue kandidáta nekvalifikuje.

*(přidávej dle libosti: Lethargy, Sonic Visions, Fuchs2, …)*
