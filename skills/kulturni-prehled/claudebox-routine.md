# Kulturní přehled — claudebox routine playbook

Playbook for the **weekly novelty watcher running headless on the
claudebox** (server-linux), launched by
`infra/claudebox/run-weekly.sh` via `kulturni-prehled-weekly.timer`
(Sat 11:00 Europe/Prague). This replaces the former Anthropic-cloud
/schedule routine. **Season planning (`/kulturni-sezona`) is a separate
manual run** — `infra/claudebox/run-sezona.sh` — never this timer.

Follow `skills/kulturni-prehled/SKILL.md` (the novelty-watcher flow)
with these substitutions. The claudebox is the best of both prior
environments: the repo checkout is native (scrapers + validator run),
only the interactive MCP connectors are missing.

| Local skill uses… | Claudebox uses instead… |
| --- | --- |
| `op` token | `$KP_DIGEST_TOKEN` env (scoped PAT: `digest:read feedback:sign digest:send events:read season:read season:write`), injected by run-weekly.sh from a 0600 file — never print it |
| `/v1/events` history queries (same-work hard veto) | work as-is — the PAT carries `events:read` (read-only; mutations stay unrestricted-only) |
| local `google-workspace` MCP (calendar) | nothing to substitute — the calendar now comes from `GET /v1/season/calendar` (SKILL.md step 2), same as on a workstation. `available: false` → empty blocked set + a footer note in the email |
| Gmail send via workspace MCP | **`POST /v1/digest/send`** (SMTP relay; recipient is server-side). On 503/502: write the rendered HTML next to the run log and do NOT ack — there is no draft fallback here |
| Spotify connector | skip; note in `missing_sources` |
| `api.discogs.com` | `discogs` field of `GET /v1/digest/context` (never fetch Discogs directly) |

Unchanged from the local flow (unlike the old cloud routine):

- **Experts run via the Skill tool** (weekly mode, no args) — the KP
  skills are symlinked into `~/.claude/skills` on the box.
- **`ensembles/*.sh` static scrapers run natively** from the checkout.
- **`python3 skills/kulturni-sezona/bin/kp_validate.py`** runs natively
  (stdlib-only) for the `fit` checks.
- Pool-aware enrichment via the season API works — dedup keys per
  `skills/kulturni-sezona/SKILL.md`.

## Run discipline

- Work dir: use `/tmp/kp-digest-CW<n>` as the local flow does.
- The run log is the report — finish with the one-line Czech summary
  (novelty count, sent count, pool delta, watchdog count, balance hint).
- Ack (`POST …/novelties/ack`) ONLY after a successful send or a
  genuine zero-novelty week; a failed send leaves the cursor alone.
- One email per run; only novelties; never re-recommend the pool.
- Guardrails from SKILL.md apply verbatim (additive pool, no plan-state
  writes, max once per day).
