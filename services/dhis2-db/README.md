# dhis2-db

The DHIS2 database: PostgreSQL with PostGIS (default `postgis/postgis:16-3.5`), with its data in the
`dhis2-db-data` volume. It is reachable on the instance's network as `dhis2-db`. Settings are in the
instance's `dhis2-db.env`; defaults are in [`env.defaults`](env.defaults).

| Variable | Default | |
|---|---|---|
| `DHIS2_DB_IMAGE_NAME`, `DHIS2_DB_IMAGE_TAG` | `postgis/postgis`, `16-3.5` | any PostGIS image |
| `DHIS2_DB_NAME`, `DHIS2_DB_USER` | `dhis`, `dhis` | the database and its owner, the server's superuser ([below](#the-dhis2-account-is-the-superuser)) |
| `DHIS2_DB_PASSWORD` | must be set | the account's password; it is used when the data directory is first set up, so changing it later doesn't change the database account |
| `DHIS2_DB_PORT` | `5432` | the port published on the host; set it differently to run more than one instance at once |
| `DHIS2_DB_MEMORY_LIMIT` | `4g` | the container's memory limit: at least `shared_buffers` + `maintenance_work_mem` + about 1 GB ([below](#server-options-dhis2_db_opt_)) |
| `DHIS2_DB_OPT_<parameter>` | see below | PostgreSQL server settings |

`TZ` comes from `instance.env`.

## Server options (`DHIS2_DB_OPT_*`)

Each `DHIS2_DB_OPT_<parameter>` variable becomes a `-c <parameter>=<value>` flag on the `postgres`
command line. A parameter not set is left at the server's default. [`env.defaults`](env.defaults)
carries DHIS2's recommended settings (`max_locks_per_transaction=96`, `jit=off`, `max_connections=200`
and the memory settings: `shared_buffers`, `work_mem`, `maintenance_work_mem`, `temp_buffers`,
`effective_cache_size`, plus `checkpoint_completion_target`, `synchronous_commit`, `wal_writer_delay`,
`random_page_cost` and `track_activity_query_size`). Size the memory ones to the host. An instance
changes one in its `dhis2-db.env`, and adds any other there (at `create`, `DHIS2_DB_OPT_*` set in your
shell go into `dhis2-db.env`, as the manifest's `capture-env` says). Defaults live in the tools
directory, so one can't be dropped by deleting a line from an instance's file; set the value you want.

**Sizing rule: `DHIS2_DB_MEMORY_LIMIT` >= `shared_buffers` + `maintenance_work_mem` + about 1 GB** (for
connections' `work_mem` and autovacuum). An index build (a restore's `CREATE INDEX`, which runs with
these settings in the image's temporary import server too), a `VACUUM` or DHIS2's analytics can use
`maintenance_work_mem` on top of `shared_buffers`; past the limit the kernel kills the server, and
with `synchronous_commit=off` and `wal_writer_delay=10s` that can lose transactions already
committed. The defaults (1 GB each, limit `4g`) keep DHIS2's recommended values and leave 2 GB over;
raise the limit with either setting.

## The DHIS2 account is the superuser

`DHIS2_DB_USER` is the account the image's setup makes (`POSTGRES_USER`), so DHIS2 connects as the
server's superuser. That was decided for simplicity: DHIS2 2.38 and later create extensions
(such as `pg_trgm` and `btree_gin`) in their migrations, which needs that right, and a restored dump recreates
its extensions itself. The cost is a wider blast radius: anything that runs SQL as DHIS2 (a SQL view,
a compromised DHIS2) can do anything on the server, including reading files the server can. A
separate, non-superuser DHIS2 account with the extensions made in advance would narrow that.

## Restoring and summarizing

`initialize` restores the database from the entries `dhis2-db.sql`, `dhis2-db.sql.gz`,
`dhis2-db.sql.7z` or `dhis2-db.sql.zip`: a plain-format `pg_dump` ([Initializing an
instance](../../docs/restore.md)). An archive holds exactly one dump file, `.sql` or `.sql.gz`. The
import runs on the database's first start, after the image's own setup. Before it,
[`scripts/restore-pgdump.sh`](scripts/restore-pgdump.sh) drops the extensions and schemas the image
adds (PostGIS, topology, the TIGER geocoder), so the dump recreates exactly the ones its source had.
It stops at the first error, and `initialize` then removes what it made.

`pihx <name> summary` prints `[dhis2-db]`, then the row counts of `datavalue`,
`trackedentityinstance` (or `trackedentity`), `programstageinstance` (or `event`), `userinfo` and
`organisationunit` (those that exist), and `flyway <version>`, the latest successful Flyway
migration. It reads the running container or, with the instance stopped, the volume (by starting a
throwaway server on it), to compare a restore with its source.

## Backup

The `backups` service runs [`scripts/backup.sh`](scripts/backup.sh) ([Backups](../../docs/backups.md)):
a plain-format `pg_dump` of the database into `dhis2-db.sql.7z`, with the instance running. It leaves
out ownership and privileges (`-O -x`), so the dump restores under the new instance's account, and the
rows of the `analytics_*` tables, which DHIS2's analytics job rebuilds (they are the largest part of a
database). Their definitions stay, empty, since a view on one (a DHIS2 SQL view) would otherwise
fail the restore.
The database password reaches `pg_dump` through its environment, never its command line.
The image's `pg_dump` is 18 and the database 16, so the script drops the two things in its output that
the older server rejects (`SET transaction_timeout` and the `\restrict` lines). The archive
restores with `initialize --from` as `dhis2-db.sql.7z`.
