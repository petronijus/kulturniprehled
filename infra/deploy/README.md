# Deployment

Two scripts and a short manual runbook. Everything self-hosted.

## First-time setup

```bash
# On the fresh Proxmox VM, as a sudo-capable user:
git clone https://github.com/petronijus/kulturniprehled.git /tmp/kp
sh /tmp/kp/infra/deploy/setup-vm.sh
```

The script:

1. Creates a `deploy` user, adds it to `docker`.
2. Installs Docker CE + the Compose plugin (idempotent — skips if
   already installed).
3. Clones the repo to `/opt/kp` (or updates if it's already there).
4. Scaffolds `/opt/kp/.env` from `.env.example` if missing.
5. Creates `/etc/cloudflared/` for tunnel credentials.

Then **manually**:

1. Edit `/opt/kp/.env` with secrets (1Password is the source of truth).
2. Place the Cloudflare Tunnel credentials JSON into `/etc/cloudflared/`
   and point `infra/cloudflared/config.yml` at the matching UUID.
3. Bring the stack up:

   ```bash
   cd /opt/kp
   docker compose --env-file .env \
                  -f infra/docker-compose.yml \
                  -f infra/compose.prod.yml \
                  up -d
   ```

4. Drop `infra/backup/cron.example` into `/etc/cron.d/kp` (adjust the
   user/paths first).

## Routine upgrades

The API image is **built and pushed to GHCR locally** (not on the VM, not in
CI) — build it first on your dev machine:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u petronijus --password-stdin   # PAT: write:packages
scripts/build-push.sh        # builds + pushes ghcr.io/petronijus/kulturniprehled-api:{sha,latest}
```

Then upgrade on the VM (pulls the image, no build):

```bash
ssh deploy@kp-vm
docker login ghcr.io -u petronijus     # one-time, if the package is private
/opt/kp/infra/deploy/upgrade.sh
```

The script:

1. `git pull --ff-only` so the local tree matches `main` (compose files +
   migration metadata; the app itself is **not** built here).
2. `docker compose pull api` to fetch the prebuilt image from GHCR.
3. Runs Alembic migrations once up-front, **before** restarting the API.
4. Rolls the API container (pulled image, `--no-deps`, no `--build`).
5. Polls `/healthz` for 30 s and reports failure with the last 50 log
   lines if the new container doesn't come up.

Postgres and MinIO are **not** restarted by the script — bump them
manually after reviewing release notes for each service.

## HTTPS front for the planner (deployed 2026-08-30)

The planner is reachable at **<https://kulturniprehled-plan.bastla.com/app/>**
from the home network. It is not a nicety: Spotify's embed player only
plays full tracks in a **secure context** — over plain `http://<LAN IP>` the
browser exposes no EME, so every piece stopped after a 30-second preview.

How it is wired:

- `infra/compose.internal-web.yml` runs Caddy (image built locally and
  pushed to GHCR, like the API) publishing `:443` on the VM and proxying to
  `api:8000`. Requests through it carry no `CF-Connecting-IP`, so the
  login-less trusted-LAN path and `/app` work exactly as on the LAN port,
  while the Cloudflare-tunnel path keeps 404ing `/app`.
- The certificate is a real Let's Encrypt one, obtained by **DNS-01**
  through the Cloudflare API (`CLOUDFLARE_DNS_API_TOKEN` in `/opt/kp/.env`,
  needs Zone:DNS:Edit). The name therefore never needs to resolve publicly.
- The name resolves **only at home**: an OPNsense Unbound host override
  points it at the VM's LAN IP. Away from home there is no record, so the
  planner is simply not there (the mobile app talks to the public API and
  is unaffected).

Bring it up (or back up) with:

```bash
cd /opt/kp/infra
docker compose --env-file /opt/kp/.env -p kulturniprehled-dev \
    -f docker-compose.yml -f compose.internal-web.yml up -d caddy
```

🚨 **`KP_API_TAG` must be set in `/opt/kp/.env`** (it is). Any ad-hoc
`docker compose up` re-creates `api` from `${KP_API_TAG:-latest}`, and the
VM's local `latest` tag is whatever was pulled last — running an image
older than the database's Alembic head crash-loops the API on
`Can't locate revision identified by '00XX'`. Recovery is to re-run with
the right tag; keeping the tag pinned in `.env` prevents it.

## Disaster recovery

See `infra/backup/restore-test.sh` for the drill. The recipe:

1. Latest dump in MinIO `backups/postgres/` (mirrored to B2 daily).
2. Spin a fresh Postgres, restore via `pg_restore`.
3. Repoint the running API to the restored DB. Tickets in MinIO are
   already mirrored to B2 — restore that bucket the same way.

## Optional: GlitchTip error reporting

If you set `SENTRY_DSN` in `.env`, the API and Flutter clients will
report errors to that DSN. To self-host the receiver, copy
`infra/compose.glitchtip.yml` into the stack:

```bash
docker compose --env-file .env \
               -f infra/docker-compose.yml \
               -f infra/compose.prod.yml \
               -f infra/compose.glitchtip.yml \
               up -d
```
