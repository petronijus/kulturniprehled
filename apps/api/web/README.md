# Season-planner SPA

React 19 + Vite single-page app served same-origin by the FastAPI
backend at `/app`. Petr finalizes his cultural-season plan here:
calendar left, candidate cards right, scenario tabs on top, drag & drop
(or the ✓/✕ buttons — full keyboard-accessible equivalent).

## Commands

```bash
npm run dev      # vite dev server on :5173, /v1 proxied to localhost:18000
npm run check    # biome lint+format check + tsc --noEmit   (pre-merge gate)
npm run test     # vitest — domain logic (ISO weeks, violations engine)
npm run build    # type-check + production bundle into dist/
```

## Configuration

- `VITE_KP_GOOGLE_CLIENT_ID` — the Google **Web** OAuth client id
  (same one the mobile apps use as `serverClientId`). Baked in at build
  time; `scripts/build-push.sh` injects it into the Docker build from
  1Password. For local dev put it in `web/.env.local`:

  ```
  VITE_KP_GOOGLE_CLIENT_ID=<client id>
  ```

  and make sure `http://localhost:5173` is among the client's
  authorized JavaScript origins.

## Architecture notes

- **Server state**: the whole season pool is fetched once
  (`api/queries.ts`) and filtered client-side; mutations are optimistic
  with 409 → refetch recovery (`api/mutations.ts`).
- **Rules**: `src/domain/violations.ts` mirrors the constraint canon in
  `skills/kulturni-sezona/bin/kp_validate.py` — change the canon first,
  mirror second. Violations are advisory, never blocking.
- **Scenario preview** is pure client state (diff ghosts on the
  calendar); only "Použít scénář" mutates, via
  `POST /v1/season/scenarios/{id}/apply`.
- **Auth**: GIS button flow → `POST /v1/auth/google`; access token in
  memory, refresh token in localStorage, single-flight refresh (the
  backend's rotation reuse-detection makes that correctness, not
  optimization).
- **Design tokens** live in `src/styles/tokens.css` (`light-dark()`
  theming) — edit that file to retune the look; components never
  hard-code visual values.
