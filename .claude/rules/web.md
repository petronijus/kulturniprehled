---
paths:
  - "apps/api/web/**"
---
# Season-planner SPA (apps/api/web)

- React + Vite, served by the API at `/app`; home-only and login-less by
  design (trusted LAN), so it has no auth code.
- `src/domain/violations.ts` mirrors `skills/kulturni-sezona/bin/kp_validate.py`,
  the constraint canon: change the canon first, then the mirror, with tests
  on both sides.
- Biome + `tsc --noEmit` (`just lint-web`), vitest for domain logic
  (`just test-web`). `dist/` is build output.
- Code, identifiers and UI strings are English.
