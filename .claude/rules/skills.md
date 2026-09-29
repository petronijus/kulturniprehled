---
paths:
  - "skills/**"
  - "infra/claudebox/**"
---
# Skills and claudebox scripts

- The skills are symlinked into `~/.claude/skills/` on Petr's machines and
  run headless on the claudebox; a change here is live on the next run.
- Scripts are stdlib-only and Python 3.9-compatible (each machine's own
  `python3`); tests run as `python3 <test file>`.
- `kp_validate.py` is the constraint canon; the SPA mirrors it.
  `dedup_key` follows the recipe in `kulturni-sezona/SKILL.md` — never
  retitle before hashing.
- Scrapers fail silently: verify a listing against its detail page when a
  time or a count looks odd, paginate every listing, and match a city only
  in the "Ensemble • Město" position (visiting orchestras carry their home
  city in the name).
- Only `kulturni-prehled` sends e-mail; the domain experts return JSON.
