# Kulturní přehled on the claudebox

Headless Claude runs on server-linux (the claudebox), modeled on
ai-config's repo-maintenance runner: `claude -p` on the operator
subscription, tool allow-list, systemd user units, logs under
`~/.config/kulturni-prehled/logs/`.

Two runs live here:

| Run | Trigger | Playbook | Token |
| --- | --- | --- | --- |
| **Weekly novelty watcher** | `kulturni-prehled-weekly.timer`, Sat 11:00 Europe/Prague | `skills/kulturni-prehled/claudebox-routine.md` | scoped PAT from `~/.config/kulturni-prehled/kp-token` (0600) |
| **Season planning** | manual `run-sezona.sh` (via `ssh -t`) | `skills/kulturni-sezona/SKILL.md` + inline substitutions | full PAT fetched from 1Password at launch (interactive) |

## One-time setup

1. Repo checkout at `~/Documents/Dev/kulturniprehled` (run scripts
   `git pull --ff-only` on every start).
2. KP skills symlinked into `~/.claude/skills` (loop in
   `skills/kulturni-prehled/README.md`).
3. **Scoped PAT** — mint on the prod VM and place on the claudebox
   without it ever touching a terminal:

   ```bash
   # on the VM (192.168.20.101), from /opt/kp:
   docker compose -f infra/docker-compose.yml --env-file .env exec -T api \
     python -m kp_api.cli mint-pat --email <owner-email> --name claudebox-weekly --quiet \
     --scope digest:read --scope feedback:sign --scope digest:send \
     --scope events:read --scope season:read --scope season:write
   # pipe the output straight into:
   #   ssh claudebox 'umask 077; mkdir -p ~/.config/kulturni-prehled; cat > ~/.config/kulturni-prehled/kp-token'
   ```

4. Optional — blocked-day checks: nothing to do on this box. The shared
   calendar's **secret iCal address** (Google Calendar → Settings →
   Kocourek&Prdelčička → "Secret address in iCal format") belongs in the
   API's `.env` as `CALENDAR_ICS_URL` on the app VM; the routine reads
   the classification from `GET /v1/season/calendar`. Without it the
   weekly email just notes that calendar conflicts were not checked.
5. Install units:

   ```bash
   ln -sf ~/Documents/Dev/kulturniprehled/infra/claudebox/kulturni-prehled-weekly.{service,timer} \
     ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now kulturni-prehled-weekly.timer
   ```

6. Optional notify hook: executable `~/.config/kulturni-prehled/notify`
   receives the run log on stdin (wire HA push / e-mail there).

## Environment differences (vs. the old Anthropic-cloud routine)

The claudebox has the full repo, so `ensembles/*.sh` scrapers and
`kp_validate.py` run natively and experts are invoked via the real
Skill tool. What it does NOT have: interactive MCP connectors — no
Spotify (skipped), no google-workspace (calendar comes from the ICS
URL, e-mail goes through `POST /v1/digest/send`).

The `cloud-routine.md` playbook is retired with the /schedule routine —
kept in git history only.
