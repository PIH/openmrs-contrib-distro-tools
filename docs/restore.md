# Initializing an instance

`initialize` fills a new instance's two volumes, `db-data` and `openmrs-data`, before its first
start: much faster than letting OpenMRS build them up from nothing, and the way to move a server's
data onto an instance.

```bash
openmrs-docker <name> initialize
```

It runs only on an instance that has never been started, and refuses if any of its volumes exists,
so it can't overwrite data.

## Sources

Each volume's source is chosen separately, so e.g. the database can come from a backup while
`openmrs-data` comes from the nightly seed image. By default (only `SEED_IMAGE_NAME` set) both come
from the seed image. A `RESTORE_*` variable replaces one volume's source for that run; set it on the
command line, not in `env`.

| Variable | Fills | Source |
|---|---|---|
| `SEED_IMAGE_NAME` / `SEED_IMAGE_TAG` (in `env`) | either, if not given below | the distro's nightly seed image |
| `RESTORE_MYSQL_DUMP_PATH` | `db-data` | a `.sql`/`.sql.gz` dump, imported by MySQL on first start; or a `.7z`/`.zip` holding one (e.g. from `backup-mysqldump`) |
| `RESTORE_MYSQL_DATA_PATH` | `db-data` | a ready MySQL data directory, copied in before MySQL starts (much faster for a large database) |
| `RESTORE_MYSQL_PERCONA_PATH` | `db-data` | a Percona/xtrabackup backup: a `.7z`/`.zip`/`.tar.gz`/`.tgz`/`.tar` (e.g. a legacy nightly `percona.7z`, or `backup-percona --output=<name>.7z`) or a directory ([below](#percona-backups)) |
| `RESTORE_OPENMRS_DATA_PATH` | `openmrs-data` | a directory, or a `.tar.gz`/`.tgz`/`.tar`/`.7z`/`.zip` of one (e.g. from `backup-openmrs-data-directory`) |
| `ARCHIVE_PASSWORD` | | the password for a protected `.7z`/`.zip` |
| `INITIALIZE_DB_TIMEOUT` | | seconds to wait for the restored database to become healthy (default 3600: a large import, or crash recovery of a large data directory, can take long) |

`db-data` needs exactly one source. `openmrs-data` needs none: without `RESTORE_OPENMRS_DATA_PATH`
or `SEED_IMAGE_NAME`, OpenMRS builds it up on its first start, as on a fresh install (e.g. for a
database backup with no matching data directory backup).

A seed image is used once, and carries a whole database: `initialize` removes it once the volumes
are filled if it pulled it, and keeps one that was already on the host (e.g. built locally).

Archives are extracted into a volume, never onto the host. A dump archive must hold exactly one dump
(`.sql` or `.sql.gz`). An `openmrs-data` archive with a single top-level folder (as
`backup-openmrs-data-directory` makes) has that folder's contents restored; otherwise its top level
is used as is.

```bash
# the database from a dump, openmrs-data from the seed image
RESTORE_MYSQL_DUMP_PATH=/path/to/backup.sql.gz openmrs-docker <name> initialize

# both volumes from backups, no seed image
RESTORE_MYSQL_DATA_PATH=/path/to/datadir RESTORE_OPENMRS_DATA_PATH=/path/to/data-dir openmrs-docker <name> initialize

# only the database; openmrs-data built up on the first start
RESTORE_MYSQL_DATA_PATH=/path/to/datadir openmrs-docker <name> initialize

# both volumes from backup-mysqldump / backup-openmrs-data-directory archives
ARCHIVE_PASSWORD=<password> RESTORE_MYSQL_DUMP_PATH=/path/to/backup.sql.7z \
    RESTORE_OPENMRS_DATA_PATH=/path/to/openmrs-data.7z openmrs-docker <name> initialize
```

## Percona backups

`RESTORE_MYSQL_PERCONA_PATH` takes a Percona/xtrabackup backup as it is. In a temporary
`percona-staging` volume, `initialize` extracts the archive (or copies the directory), unwrapping a
single top-level folder, so both a flat legacy `percona.7z` and an archive holding one
`<name>-percona/` folder work. It then runs `innobackupex --apply-log` if the backup isn't prepared
yet (legacy nightly backups are), copies it into `db-data` with `--copy-back`, and removes the
staging volume. Nothing unencrypted is written to the host, and it needs about twice the database's
size on Docker's volumes. Anything without an `xtrabackup_checkpoints` file is refused.

```bash
ARCHIVE_PASSWORD=<password> RESTORE_MYSQL_PERCONA_PATH=/path/to/percona.7z openmrs-docker <name> initialize
```

To turn a Percona backup into a plain data directory by hand instead (e.g. to inspect it first), use
the [utilities](utilities.md):

```bash
BACKUP_DIR=$(openmrs-utils extract-archive --path=/path/to/backup.7z --output-dir=./backup)
DATADIR=$(openmrs-utils convert-percona-backup --backup-dir="$BACKUP_DIR" --output-dir=./datadir)
RESTORE_MYSQL_DATA_PATH="$DATADIR" openmrs-docker <name> initialize
```

## Database accounts after a physical restore

A physical backup (`RESTORE_MYSQL_DATA_PATH`, `RESTORE_MYSQL_PERCONA_PATH`) is a copy of the source
server's whole data directory, *including its `mysql` system tables*, so it arrives with the source's
accounts and passwords (the image only creates its own on an empty data directory). `initialize`
sets them to this instance's before the database first starts, with `reset-mysql-accounts`: every
`root` and `OPENMRS_DB_USER` account gets this instance's password, `OPENMRS_DB_USER@'%'` (how the
openmrs container connects) and `root@'%'` are created if missing, and anonymous accounts are
removed. The source's other accounts (e.g. PETL or backup users) are kept, and `initialize` lists
them so you can remove the ones you don't need. `OPENMRS_DB_IMAGE_TAG` should still match the MySQL
version the backup was taken from. A dump doesn't carry accounts, so `RESTORE_MYSQL_DUMP_PATH` isn't
affected.

## openmrs-data after a restore

Restored files keep the owners they had on the source host, so `initialize` gives everything in
`openmrs-data` to the openmrs image's runtime user (read from the image, e.g. `1001:0` for PIH's
images). Set `OPENMRS_DATA_OWNER=<uid>:<gid>` to choose it instead.

It also moves a restored `openmrs-runtime.properties` aside to `openmrs-runtime.properties.restored`
(`openmrs-utils runtime-properties --set-aside`). That file holds the source server's connection
settings, which would win over this instance's: openmrs-core 2.6+ only merges `OMRS_EXTRA_*` into an
existing file. OpenMRS writes a fresh one from the instance's `env` on its first start.

With no runtime properties in `openmrs-data` (set aside, or nothing restored or seeded), OpenMRS
would take the database for a new install and create every table again, so `initialize` adds
`OPENMRS_CREATE_TABLES=false` to `env` (unless it's already set).

### Carrying over runtime properties

**Nothing else from the source server's runtime properties file is carried over.** The new file has
only the connection settings, `pih.config`, `activitylog_enabled`, the image's own properties and the
instance's `OMRS_EXTRA_*` variables. Anything else the source had (mail, integration credentials,
`encryption.key` / `encryption.vector`, paths, ...) is gone until you set it for this instance.
Which keys to carry over is your call: go through the whole source file. After the first start,
compare the two:

```bash
docker run --rm -v <name>_openmrs-data:/data alpine:3.21 sh -c '
  for f in openmrs-runtime.properties.restored openmrs-runtime.properties; do
    grep -v "^[[:space:]]*\(#\|!\|$\)" "/data/$f" | sort > "/tmp/$f"
  done
  diff /tmp/openmrs-runtime.properties.restored /tmp/openmrs-runtime.properties'
```

If `openmrs-data` wasn't restored, there's no `.restored` file: take a copy of the source server's
`openmrs-runtime.properties` and add `-v /path/to/that/copy:/data/openmrs-runtime.properties.restored:ro`
to the command.

Lines starting with `-` are only in the source file, or have a different value there. OpenMRS writes
the new file in Java's properties format, so `\:` / `\=` there (e.g. `jdbc\:mysql\://...`) is the
same value as the source's without the backslashes. `connection.*`, `auto_update_database` and
`module.allow_web_admin` are this instance's own. Paths from the source host (e.g.
`custom.images.dir`) need pointing under `/openmrs/data`. **Always carry over `encryption.key` and
`encryption.vector`**: the first start generates new ones, and anything encrypted with the source's
(e.g. authentication module 2FA secrets) can't be read otherwise. If the source file has none, it
used core's defaults (`OpenmrsConstants.ENCRYPTION_KEY_DEFAULT` / `ENCRYPTION_VECTOR_DEFAULT`); set
those.

To set a property on an instance you manage by hand (a local or dev instance), add it to the
instance's `env` and start it again:

```bash
# lowercase keys: OMRS_EXTRA_<key>, with '_' written as '__' and '.' as '_'
OMRS_EXTRA_mail_smtp_host='smtp.example.org'
OMRS_EXTRA_terms__and__conditions__enabled='true'
# keys that aren't lowercase: -D<key>=<value> in OMRS_JAVA_SERVER_OPTS, after the image's defaults
OMRS_JAVA_SERVER_OPTS='-Dfile.encoding=UTF-8 -server -Djava.security.egd=file:/dev/./urandom -Djava.awt.headless=true -Djava.awt.headlesslib=true -Dmail.smtp.socketFactory.class=javax.net.ssl.SSLSocketFactory'
```

```bash
openmrs-docker <name> start    # not restart: restart doesn't pick up env changes
```

`OMRS_EXTRA_*` values are merged into the runtime properties file on every start, overriding it
([env](env.md#runtime-properties-omrs_extra_)); removing one later leaves its last value in the
file. On an instance whose `env` puppet manages (mirebalais-puppet's `openmrs_docker` module), set
them with the module's `runtime_properties` / `java_system_properties` instead: puppet rewrites `env`
on every apply. Once you've finished comparing, delete `openmrs-runtime.properties.restored` (it
holds the source's secrets).

## Checking a restore

Fingerprint the source before the backup with `openmrs-utils fingerprint`, and the new instance after
`initialize` and before its first start with `openmrs-docker <name> fingerprint`, then `diff`. The
instance command reads its stopped volumes with the instance's own database image and
`OPENMRS_DB_OPT_*` options, so `[server]` shows what the running instance will have. Expect
`[accounts]` to differ, a physical restore to bring along other databases the source had, and
`[server]` to differ only where the two servers are configured differently:

```bash
MYSQL_PASSWORD=<root password> openmrs-utils fingerprint --container=<source db container> \
    --data-dir=<source data dir> --output=before.txt
openmrs-docker <name> fingerprint --data-dir --exclude-distribution-artifacts --output=after.txt
diff before.txt after.txt
```

## Disk space

Before creating any volume, `initialize` estimates what the restore will write and stops if Docker's
volume filesystem has less free than that plus 10%, rather than failing part way with half-filled
volumes. The estimate is a data directory's size, a dump's uncompressed size (twice for a
`.7z`/`.zip`, which is extracted into a temporary volume first), a Percona backup's (twice:
extracted, then copied in), and an `openmrs-data` directory's or archive's uncompressed size; a seed
image isn't counted. A dump import usually needs more than the dump itself (MySQL builds the indexes
too), so for dumps this catches "nowhere near enough" rather than a tight fit. `extract-archive`,
`backup-percona`, `convert-percona-backup` and `backup-openmrs-data-directory` check their output's
filesystem the same way. `SKIP_DISK_SPACE_CHECK=true` goes ahead anyway.
