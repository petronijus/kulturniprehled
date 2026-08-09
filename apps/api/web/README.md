# Season-planner SPA

React 19 + Vite single-page app served same-origin by the FastAPI
backend at `/app`. Petr finalizes his cultural-season plan here:
calendar left, candidate cards right, scenario tabs on top, drag & drop
(or the ✓/✕ buttons — full keyboard-accessible equivalent).

**Home-only and login-less**: with `WEB_PUBLIC=false` (default) the
backend refuses `/app` requests that came through the Cloudflare Tunnel,
and with `WEB_TRUSTED_LAN=true` direct requests from the home network get
a season-scoped principal automatically — the network IS the auth. Reach
it via LAN `http://192.168.20.101:18000/app`, over Tailscale, or (with
the optional caddy overlay) `https://kulturniprehled-plan.bastla.com/app`.

## Commands

```bash
npm run dev      # vite dev server on :5173, /v1 proxied to localhost:18000
npm run check    # biome lint+format check + tsc --noEmit   (pre-merge gate)
npm run test     # vitest — domain logic (ISO weeks, violations engine)
npm run build    # type-check + production bundle into dist/
```

## Configuration

No build-time configuration — the SPA is login-less and fully
self-contained. In dev, run the API with `WEB_TRUSTED_LAN=true` so the
vite proxy's header-less requests authenticate as the trusted-LAN
principal.

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
- **Auth**: none in the SPA. The backend's trusted-LAN mode
  (`WEB_TRUSTED_LAN`) authenticates direct home-network requests as the
  workspace owner restricted to the `season:*` scopes; a 401 renders as
  "dostupné jen z domácí sítě".
- **Design tokens** live in `src/styles/tokens.css` (`light-dark()`
  theming) — edit that file to retune the look; components never
  hard-code visual values.
