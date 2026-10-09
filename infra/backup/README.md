# Backup scripts

Wire these up after milestone M1 when the database schema exists.

Planned:

- `pg_dump.sh` — nightly logical dump of the Postgres database, written into
  the MinIO `backups/` bucket.
- `mc_mirror.sh` — mirrors the MinIO `tickets` and `backups` buckets to a
  Backblaze B2 remote.
- `restore-test.sh` — quarterly drill that restores the latest dump into a
  scratch database and runs a smoke query.

All three run `mc` through the stack's `minio-init` service with
`--entrypoint /bin/sh` (the service's own entrypoint would otherwise run its
bucket-init script instead), take the MinIO credentials from that service's
environment, and stream dumps over stdin/stdout rather than bind-mounting
host temp files, which the nonroot (`65532`) MinIO image cannot read.
