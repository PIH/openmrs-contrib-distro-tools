# Backups

The `backups` service backs an instance up on a schedule, with the instance running, into encrypted
archives in a Docker volume, and uploads them off-site (to Azure, so far). A backup restores into a
new instance with `initialize --from` ([Initializing an instance](restore.md)), and the restored
instance's `summary` matches the source's ([Checking a restore](restore.md#checking-a-restore)).

```bash
BACKUP_ARCHIVE_PASSWORD=<a password> pihx <name> add-service backups
pihx <name> update
```

That keeps the runs in the volume only. Uploading them is `BACKUP_UPLOAD=azure` and the
`BACKUP_AZURE_*` settings in `backups.env`.

Its settings are in `backups.env`; they're listed in its [README](../services/backups/README.md).

## How it works

- **In the instance, not on the host.** The backups service is a container in the instance
  (`<name>-backups`, image `partnersinhealth/backup-tools`, [`images/backup-tools`](../images/backup-tools))
  that runs two jobs on their schedules with [supercronic](https://github.com/aptible/supercronic),
  which never starts a job while its previous run is still going. Nothing is installed on the host,
  and the container has no Docker socket: it reaches databases over the instance's network and data
  volumes read-only, as each service's `with-backups.yaml` gives it.
- **The backup job** (`BACKUP_SCHEDULE`, default 01:30 every night in the instance's `TZ`) writes one
  directory per run, `<prefix>_<UTC timestamp>/`, at the root of the `<name>_backups` volume. Each
  service with a backup script writes its own file into it (`openmrs-db.sql.7z`, `openmrs.7z`), and
  the run's output goes to its `backup.log` and the container's log (`pihx <name> logs backups`).
  A run is written as `<run>.partial` and renamed only when every service's script succeeded. One that
  failed (a script failed, there wasn't room, or no service wrote anything) is renamed `<run>.failed`
  and keeps only its `backup.log`, so a job failing every night doesn't fill the disk. One script
  failing doesn't stop the others, so the log shows everything that went wrong.
- **The upload job** (`BACKUP_UPLOAD_SCHEDULE`, default hourly) uploads each complete run not yet
  uploaded, oldest first, to the destination `BACKUP_UPLOAD` names; empty means no uploads. Running
  hourly, it keeps retrying after an outage until it gets through, however many days that takes. A
  run counts as uploaded only once the destination is shown to hold every one of its files at its
  local size; then the job writes the marker `.uploaded/<run>` in the volume, which is all cleanup and
  `list-backups` go by.
- **The `azure` destination**, the one so far: each run goes to
  `${BACKUP_AZURE_URL}/${BACKUP_AZURE_PATH}/<run>/` with `azcopy`, using the SAS token
  `BACKUP_AZURE_SAS`, and is checked by listing it. Nothing in Azure is ever deleted or overwritten
  (files already there are skipped), and the SAS token never appears in the output. Another
  destination is one script beside `upload.sh` ([README](../services/backups/README.md)).
- **Cleanup.** After each upload, uploaded runs are deleted from the volume except the newest
  `BACKUP_KEEP_LOCAL` (default 3); a run that isn't uploaded is never deleted. Without uploads
  (`BACKUP_UPLOAD` empty, e.g. a developer's instance), the backup job keeps the newest
  `BACKUP_KEEP_LOCAL` runs instead. `.failed` and stale `.partial` runs older than the newest complete
  one are deleted too. `BACKUP_KEEP_LOCAL=all` deletes nothing.
- **Disk space.** A run needs the size of the newest complete run (1 GiB before the first) plus
  `BACKUP_MIN_FREE` (default 2G) free in the volume, which shares the disk with the database, or it
  fails before any script runs. `sqlserver`'s backup also checks, before it starts, for room for its
  uncompressed `.bak` files beside their archive (twice the chosen databases' used space, plus 10%).
- **Encryption.** Every archive is 7-Zip, encrypted with `BACKUP_ARCHIVE_PASSWORD`. The dumps
  (`openmrs-db`, `dhis2-db`, `openhim`) stream straight into their archives, so they're never on disk
  unencrypted. Their password is on 7-Zip's command line while each dump runs (the dump is on its
  standard input), and a container's processes show in the host's process list: any user on the host
  can read it with `ps` for those minutes. 7-Zip has no other way to take a password with the data on
  standard input (it reads part of the data with the password, and a named pipe is stored as a pipe,
  not read). For the archives made from files (`openmrs`'s and `dhis2`'s data, `biometrics`' copy,
  `sqlserver`'s `.bak` files) the password goes on standard input. Mounting the host's `/proc` with
  `hidepid=2` hides other users' processes.
- **Status.** `status.json`, at the root of the volume, holds for each job its last attempt, last
  result, last error and last success; the services not backed up; and the runs and bytes waiting to
  upload. It's for monitoring to read (TASKS-603). `pihx <name> list-backups` shows it.

### What each service backs up

Each service's manifest says what happens to its data (its `backup` field,
[Writing a service](services.md#backup)):

| Service | Backup |
|---|---|
| `openmrs-db` | `openmrs-db.sql.7z`: a single-transaction `mysqldump` of the `openmrs` database, as root, with routines and triggers |
| `openmrs` | `openmrs.7z`: the `openmrs-data` volume as one directory, `openmrs/`, without the distribution artifacts (the contents of `modules/`, `owa/`, `configuration/` and `frontend/`, and `.openmrs-lib-cache`, which the image puts back on every start) and without the paths in `OPENMRS_DATA_BACKUP_EXCLUDES`. Taken with OpenMRS running |
| `biometrics` | `biometrics.db.7z`: the fingerprint templates' SQLite database, `biometrics.db`, copied whole with SQLite's online backup while the server runs (it waits for a writer's lock, up to a minute, and holds a read lock only for the local copy). The copy is staged in `.backup-staging` beside the database until it's archived. Not `biometrics-licensing`: the license's machine identity, which belongs to the host |
| `openhim` | `openhim.archive.7z`: a `mongodump` archive of the `openhim` database, which is the transaction log, audit events and metrics. Its configuration is rebuilt on every start (`openhim-setup`, and each mediator provisions its channels and clients), so restoring it only brings back that history |
| `sqlserver` | `sqlserver.7z`: a `<db>.bak` (full, `COPY_ONLY`) of each database in `SQLSERVER_BACKUP_DATABASES`, which is empty by default: what an instance keeps there is usually rebuilt (e.g. by PETL), so it's chosen per instance. With none chosen, each run names `sqlserver` as not backed up |
| `dhis2-db` | `dhis2-db.sql.7z`: a plain-format `pg_dump` of the DHIS2 database (without ownership and privileges, and without the `analytics_*` tables' rows, which DHIS2's analytics job rebuilds: the tables are there, empty, so views on them restore) |
| `dhis2` | `dhis2.7z`: the `dhis2-data` volume as one directory, `dhis2/`, holding everything in it but `dhis.conf` (`dhis2-setup` writes it on every start, and it holds the database password), `.dhis.conf.new` (left by a setup that failed before renaming it; it holds the password too) and `logs/`: `files/`, `apps/`, the version marker `.dhis2-version`, and anything else DHIS2 keeps in its home. Taken with DHIS2 running |
| `petl`, `openmrs-smoke-tests`, `openhim-advapacs-mediator`, `modality-simulator`, `advapacs-gateway` | nothing to back up (each manifest says why; `advapacs-gateway` holds only its upload queue, and its configuration is in AdvaPACS) |

A service whose script writes nothing named after it is recorded as not backed up for that run, like
a service with no script: each run's log and `status.json` name them.

The database dump is taken with the backup image's MySQL 8.4 client, which dumps MySQL 5.6 to 8.4
and MariaDB (`--column-statistics=0`). SQL Server writes each `.bak` into its own volume
(`.backup-staging`), unencrypted beside the database's files, until it's archived; it's deleted
then.

## Commands

```bash
pihx <name> backup                 # run the backup job now
pihx <name> upload-backups         # run the upload job now
pihx <name> list-backups           # the runs in the volume, and the jobs' last results
pihx <name> copy-backup <run>|latest --to=<dir>
```

`backup` and `upload-backups` run the job in the running backups container, holding the instance
lock, and show its output as it goes; they exit with the job's status. If a scheduled run is already
going, either job says so and exits non-zero, having done nothing.

`list-backups` shows each run with its state (complete, failed, or partial: being written, or left by
a job that was stopped), size, and whether it's uploaded; then the jobs' status. It reads the volume
in a throwaway container, so it works with the instance stopped too.

`copy-backup` copies a complete run (or the newest, `latest`) into `--to`, a new or empty directory,
as you. That directory is what `initialize --from` takes.

The scheduled jobs run inside the container, so they don't hold the instance lock ([One command at a
time](instances.md#one-command-at-a-time)). Instead, `stop`, `initialize` and `destroy` stop the
container with the rest of the instance, so nothing is backed up while an instance is stopped. An
`update` that recreates the container during a run leaves a `.partial` run, which a later cleanup
removes.

## Restoring

A run directory is what `initialize --from` takes, as it is: each file is named after its service,
and `backup.log` is ignored.

**On the same host** (a bad deploy, a damaged database), from a run still in the volume. `initialize`
refuses volumes that exist, so the damaged ones go first, by hand, once the copy is out and checked:

```bash
pihx <name> copy-backup latest --to=/tmp/run
ls -l /tmp/run                                   # openmrs-db.sql.7z, openmrs.7z, backup.log
pihx <name> stop
docker volume rm <name>_db-data <name>_openmrs-data
ARCHIVE_PASSWORD=<the archive password> pihx <name> initialize --from /tmp/run
pihx <name> start
```

(On a development or test instance, `destroy` and `create` instead of removing the volumes by hand
also work: `destroy` keeps the backups volume. On a Puppet host `destroy` refuses.)

**On another host**, from the upload destination; for `azure`:

```bash
azcopy copy "<BACKUP_AZURE_URL>/<BACKUP_AZURE_PATH>/<run>/?<SAS with read and list>" /tmp --recursive
ARCHIVE_PASSWORD=<the archive password> pihx <name> initialize --from /tmp/<run>
```

`pihx <name> summary` covers every backed-up service, so a source summarized after its backup and
the restored instance summarized before its first start compare with one `diff`: `[biometrics]`
(each table's rows), `[openhim]` (each collection's documents and the newest transaction) and
`[sqlserver]` (each table's rows in the databases in `SQLSERVER_BACKUP_DATABASES`), beside
`openmrs-db`'s and `openmrs`'s sections. For a stopped instance, `openhim`'s and `sqlserver`'s start
a throwaway server of the instance's image on the volume (a minute or so for SQL Server).

`initialize` refuses a restored service's volumes that exist (`openmrs-db`'s `db-data`, `openmrs`'s
`openmrs-data`, `biometrics`' `biometrics-data`, `openhim`'s `mongo-data`, `sqlserver`'s
`sqlserver-data`), and leaves the others alone. What each restore does beyond filling its volume:

- **biometrics**: `biometrics-licensing` starts new, so the license activates as a new machine, which
  can take until the old activation expires (about 30–40 minutes; [biometrics](../services/biometrics/README.md)).
- **openhim**: the restored database has the source's admin account, so `openhim-setup` succeeds on
  the first start only if the instance's `OPENHIM_PASSWORD` is the source's.
- **sqlserver**: each `.bak` restores as the database it's named after. On the first start
  `sqlserver-setup` creates the declared logins, and in each login's databases remaps the restored
  user of the same name to it; other users in a restored database keep the source server's logins,
  which don't exist here, until they're declared too. Give the restored instance the source's
  `SQLSERVER_BACKUP_DATABASES` as well, or its summary has no `[sqlserver]` section and it stops
  backing those databases up.

`destroy` keeps the instance's backups volume, and doesn't archive it, unless it's given
`--include-backups` ([Archive and destroy](instances.md#archive-and-destroy)); `archive` leaves it out.
The volume is `<name>_backups`, so once the instance is created again with the same name, its
`list-backups` and `copy-backup` reach the runs in it. `docker volume rm <name>_backups` removes it
for good.

## Not covered yet

- Monitoring and alerting from `status.json` (TASKS-603).
- Percona backups (`percona/percona.7z`) for the sites whose data warehouse refresh reads them.
- Upload destinations other than `azure`.
- What happens when the disk fills during a long outage, beyond failing the run and recording it;
  a retention rule in Azure.
