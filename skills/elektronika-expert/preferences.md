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

Primary (club sites):

- https://www.palacakropolis.cz — Palác Akropolis
- https://www.crossclub.cz/cs/program/ — Cross Club <!-- TODO(Petr): verify URL -->
- https://www.roxy.cz/program — Roxy <!-- TODO(Petr): verify URL -->
- https://anka.li/upcoming-events/ — Ankali (verified 2026-08; ankali.bio is dead DNS)
- https://punctum.cz — Punctum / Krásovka <!-- TODO(Petr): verify URL — returned an empty page 2026-08 -->

Secondary (aggregators — robust when a club site breaks; the caller
dedups against primary sources by dedup_key):

- https://ra.co/events/cz/prague — Resident Advisor Praha
- https://goout.net/cs/praha/koncerty/?tags=electronic — GoOut elektronika

*(přidávej dle libosti: Lethargy, Sonic Visions, Fuchs2, …)*
