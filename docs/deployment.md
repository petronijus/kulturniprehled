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
   1Password.
3. Create the Cloudflare Tunnel and place the credentials JSON into
   `/etc/cloudflared/`.
4. `docker compose -f infra/docker-compose.yml -f infra/compose.prod.yml up -d`
5. Run `alembic upgrade head` against the running container.
6. Set up cron jobs for `infra/backup/pg_dump.sh` and `mc_mirror.sh`.

## Quarterly drill

Run `infra/backup/restore-test.sh` in a scratch environment, verify the smoke
query and the resulting object count in MinIO match expectations.
