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


## Seat watcher (`kp-seat-watch.timer`)

A sold-out concert leaks seats back one cancellation at a time, at no
particular hour. Petr adds a watch in the planner (👁 on a sold-out card,
pasting the ticketing system's hall link); this timer is the thing that
actually looks. One timer serves every watch, so nothing needs configuring
per concert.

```bash
cp seat-watch.env.example ~/.config/kulturni-prehled/seat-watch.env
chmod 600 ~/.config/kulturni-prehled/seat-watch.env   # it holds a PAT
$EDITOR ~/.config/kulturni-prehled/seat-watch.env     # KP_TOKEN, SMTP_*
mkdir -p ~/.config/systemd/user
cp kp-seat-watch.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now kp-seat-watch.timer
systemctl --user list-timers kp-seat-watch.timer
```

The PAT needs `season:read` + `season:write` (`scripts/mint-pat.sh`).

Checks every 10 minutes. It reads the hall the way a browser does — through
the waiting room to the seat map — and needs no login and no browser,
because the hall link carries its own session in the path. That is also why
the link expires: the check then reports `content_expired`, the planner shows
"odkaz vypršel" on the card, and a fresh link revives the watch.

**It never puts a seat in a basket.** A hit sends one mail with the seats and
the link; the twenty-minute hold is Petr's to start by clicking.

Test the seat logic without a network or a hall:

```bash
python3 test_seat_watch.py     # stdlib only, same deal as kp_validate
./seat-watch.py --verbose      # one pass against the real watches
```
