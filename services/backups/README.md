# backups

Scheduled, encrypted backups of the instance's services into its `backups` volume, uploaded off-site
(to Azure, the one destination so far): [Backups](../../docs/backups.md) says how it works, how to run
and list backups, and how to restore one. Settings are in the instance's `backups.env`; defaults are
in [`env.defaults`](env.defaults).

| Variable | Default | |
|---|---|---|
| `BACKUP_ARCHIVE_PASSWORD` | none: must be set | the password every archive is encrypted with |
| `BACKUP_PREFIX` | the instance's name | run directories are `<prefix>_<UTC timestamp>`: letters, digits, `.`, `_` and `-` |
| `BACKUP_SCHEDULE` | `30 1 * * *` | when the backup job runs: a cron expression, in the instance's `TZ` |
| `BACKUP_UPLOAD_SCHEDULE` | `15 * * * *` | when the upload job runs |
| `BACKUP_KEEP_LOCAL` | `3` | complete runs kept in the volume (uploaded ones, when uploading); `all` keeps every run |
| `BACKUP_UPLOAD` | empty | where complete runs are uploaded: empty for nowhere (they stay in the volume), or `azure` |
| `BACKUP_AZURE_URL` | empty | for `azure`: e.g. `https://<account>.blob.core.windows.net/<container>` |
| `BACKUP_AZURE_PATH` | empty | where the runs go under it, e.g. `kazakhstan/endtb` |
| `BACKUP_AZURE_SAS` | empty | a SAS token with write and list on that path |
| `BACKUP_MIN_FREE` | `2G` | free space a run must leave in the volume beyond the newest run's size: bytes, or with a `K`, `M` or `G` suffix |
| `BACKUP_MEMORY_LIMIT` | `1g` | the container's memory limit |

What another service's backup needs comes from that service: `OPENMRS_DATA_BACKUP_EXCLUDES` is in
`openmrs.env` ([openmrs](../openmrs/README.md)), and the root password the dump uses is
`openmrs-db`'s.

Its image, `partnersinhealth/backup-tools`, is built from [`images/backup-tools`](../../images/backup-tools)
and referenced by its content tag. It's built for amd64 only (Oracle publishes its MySQL apt
repository for amd64 only); on an arm64 machine Docker runs it emulated, if at all.

Each upload destination is a script, `scripts/upload-<name>.sh`, that `upload.sh` sources: it checks
the destination's settings, copies a run and proves the copy is whole. `upload.sh` does the rest
(which runs, the `.uploaded/<run>` marker, status and cleanup); its header has the contract. A new
destination is that script, its mount in `compose.yaml` and its variables here.
