# Deployment

The production target is a single Proxmox VM running Ubuntu Server LTS.
Docker Compose runs the application stack; Cloudflare Tunnel exposes it
publicly without opening ports on the home network.

## VM sizing (initial estimate)

- 4 vCPU, 8 GB RAM, 100 GB virtual disk
- Tickets and DB backups are pushed offsite to Backblaze B2

## Bootstrap (rough order, to be detailed during M8 polish)

1. Provision the VM on Proxmox, install Docker and `docker compose` plugin.
2. Clone the repo, create `.env` from `.env.example`, fill in secrets from
   1Password. In production set:
   - `MINIO_PUBLIC_ENDPOINT=tickets.kp.example.com`
   - `MINIO_PUBLIC_USE_SSL=true`
   - `MINIO_SERVER_URL=https://tickets.kp.example.com` (env var on the
     MinIO container itself, so MinIO advertises the public hostname).
3. Create the Cloudflare Tunnel, mount the credentials JSON into the
   `cloudflared` container per `infra/cloudflared/config.example.yml`.
4. `docker compose -f infra/docker-compose.yml -f infra/compose.prod.yml up -d`
5. Migrations run on every API start (see `apps/api/docker-entrypoint.sh`).
6. Set up cron jobs for `infra/backup/pg_dump.sh` and `mc_mirror.sh`.

## Why tickets get their own subdomain

The MinIO presigned-URL flow signs the request host with SigV4. If the API
embedded the internal `minio:9000` URL into a signed URL and the mobile
client visited `https://tickets.kp.example.com/...`, the signature would
mismatch and MinIO would reject the request. The API therefore generates
URLs against `MINIO_PUBLIC_ENDPOINT`; the tunnel passes the request through
to MinIO unchanged. Two MinIO clients are kept in process: one bound to
the internal endpoint for server-side ops (bucket bootstrap, deletes,
integrity probes) and one bound to the public endpoint for URL generation.

## Quarterly drill

Run `infra/backup/restore-test.sh` in a scratch environment, verify the smoke
query and the resulting object count in MinIO match expectations.
