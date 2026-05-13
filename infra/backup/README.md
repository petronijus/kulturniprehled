# Backup scripts

Wire these up after milestone M1 when the database schema exists.

Planned:

- `pg_dump.sh` — nightly logical dump of the Postgres database, written into
  the MinIO `backups/` bucket.
- `mc_mirror.sh` — mirrors the MinIO `tickets` and `backups` buckets to a
  Backblaze B2 remote.
- `restore-test.sh` — quarterly drill that restores the latest dump into a
  scratch database and runs a smoke query.
