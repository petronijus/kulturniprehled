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
2. Set `CLOUDFLARE_TUNNEL_TOKEN` in `/opt/kp/.env`: `infra/compose.prod.yml`
   runs `cloudflared` with that token (a tunnel managed in the Cloudflare
   dashboard), so no credentials file or `config.yml` is mounted. Give the
   tunnel the two public hostnames listed in
   `infra/cloudflared/config.example.yml`.
3. Bring the stack up. The API and MinIO images are private GHCR
   packages, so log in once first (a PAT with `read:packages`):

   ```bash
   docker login ghcr.io -u petronijus
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

## MinIO: switching to the GHCR mirror (manual, once)

MinIO deleted `minio/minio` and `minio/mc` from Docker Hub on 2026-09-11.
The compose file now runs Chainguard's build mirrored into the private
package `ghcr.io/petronijus/minio` (why and how to refresh it:
[`docs/development.md`](../../docs/development.md#minio-image)). It runs as
nonroot `65532`, while the volume on the VM was written by the old image
as root, so the one-shot `minio-perms` service chowns it before `minio`
starts. `upgrade.sh` never touches MinIO; on the VM:

```bash
cd /opt/kp
C="docker compose --env-file .env -p kulturniprehled-dev -f infra/docker-compose.yml -f infra/compose.internal-web.yml"

# 0. The checkout must carry the change (git pull --ff-only, or copy
#    infra/docker-compose.yml over while the VM's GitHub access is broken).
grep -n '^x-minio-image' infra/docker-compose.yml

# 1. Rollback insurance. The old images can never be pulled again, so save
#    the VM's cached copies, and snapshot the data volume (postgres:16-alpine
#    is on the VM already and has tar).
docker image save minio/minio:RELEASE.2025-01-20T14-49-07Z \
    minio/mc:RELEASE.2025-01-17T23-25-50Z | gzip > ~/minio-old-images.tar.gz
docker run --rm -v kulturniprehled-dev_minio-data:/data:ro postgres:16-alpine \
    tar -C /data -czf - . > ~/minio-data-pre-switch.tar.gz

# 2. Pull. Private package: `docker login ghcr.io -u petronijus` first
#    (a PAT with read:packages).
$C pull minio-perms minio minio-init

# 3. Switch: minio-perms hands the data to 65532, then minio and minio-init
#    are re-created. The API keeps running and reconnects by itself.
$C up -d minio-perms minio minio-init

# 4. Verify.
$C ps -a minio-perms minio minio-init   # Exited (0) / Up (healthy) / Exited (0)
$C logs minio-perms minio minio-init    # perms: "N entries handed to 65532:65532"; no FATAL
$C exec minio mc ready local            # "The cluster is ready"
```

Then check the signed-URL path end to end from a client: open a ticket in
the app (or `GET /v1/tickets/{id}/url` and fetch the URL it returns).

**Rollback** works only from what step 1 saved — the old tags are gone
upstream, and if `docker image save` reports no such image there is no
rollback image at all. `docker load < ~/minio-old-images.tar.gz`, restore the
previous `infra/docker-compose.yml` (`git checkout <previous commit> --
infra/docker-compose.yml`) and `$C up -d minio minio-init`. The old image ran
as root, so the chowned files do not stop it; whether it reads data the new
build has written was not tested (only old → new was), so roll back early
or restore `~/minio-data-pre-switch.tar.gz` into the volume first.

The backup scripts in `infra/backup/` changed with the switch: before it,
their `compose run minio-init /bin/sh -c ...` was swallowed by the old
service's own `sh -c` entrypoint, so the bucket-init script ran instead and
no dump was ever uploaded, mirrored or fetched. Run `pg_dump.sh` once after
the switch and check that the dump lands in `backups/postgres/`.

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
