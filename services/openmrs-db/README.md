# openmrs-db

The OpenMRS database: MySQL (default `mysql:5.6`) or MariaDB, with its data in the `db-data` volume,
and the one-shot `openmrs-db-accounts` that keeps the declared MySQL accounts in place. Settings are
in the instance's `openmrs-db.env`; defaults are in [`env.defaults`](env.defaults).

| Variable | Default | |
|---|---|---|
| `OPENMRS_DB_IMAGE_NAME`, `OPENMRS_DB_IMAGE_TAG` | `mysql`, `5.6` | any MySQL or MariaDB image. After a physical restore, the tag should still match the version the backup came from |
| `OPENMRS_DB_USER`, `OPENMRS_DB_PASSWORD`, `OPENMRS_DB_ROOT_PASSWORD` | `openmrs` for each | the OpenMRS account and root. `openmrs` reads the account from here, so it is defined once. Neither password can contain a backslash ([below](#changing-the-passwords)) |
| `OPENMRS_DB_PORT` | `3306` | the port published on the host; set it differently to run more than one instance at once |
| `OPENMRS_DB_MEMORY_LIMIT` | `2g` | the container's memory limit |
| `OPENMRS_DB_OPT_<option>` | see below | MySQL/MariaDB server options |
| `OPENMRS_DB_ACCOUNT_<ID>_*` | none | accounts to keep in place ([below](#mysql-accounts)) |

`TZ` comes from `instance.env`. The database reads the time zone rules from the host's
`/usr/share/zoneinfo`, since older images' are out of date (`mysql:5.6` still has daylight saving
time for Mexico City).

## Server options (`OPENMRS_DB_OPT_*`)

Each `OPENMRS_DB_OPT_<option>` variable becomes a `--<option>=<value>` flag on the
`mysqld`/`mariadbd` command line, with `_` in the name turned into `-` (MySQL and MariaDB treat the
two the same in option names). An empty value gives a bare flag: `OPENMRS_DB_OPT_skip_name_resolve=`
becomes `--skip-name-resolve`. An option not set is left at the server's own default, so the same
settings carry over to another MySQL or MariaDB version as long as each option exists there.

[`env.defaults`](env.defaults) sets these; an instance changes one in its `openmrs-db.env`, and adds
any other (at `create`, `OPENMRS_DB_OPT_*` set in your shell go into `openmrs-db.env`, as the
manifest's `capture-env` says):

| Option | Default |
|---|---|
| `character_set_server` | `utf8` |
| `collation_server` | `utf8_general_ci` |
| `max_allowed_packet` | `1G` |
| `innodb_buffer_pool_size` | `1G` |
| `net_read_timeout`, `net_write_timeout` | `3600` |
| `log_bin_trust_function_creators` | `1` (only matters when binary logging is on, e.g. by default on MySQL 8+: lets PETL create functions) |

Defaults live in the checkout, so one can't be dropped by deleting a line from an instance's file;
set it to the value you want instead. Binary logging, e.g. for a CDC tool such as Debezium, is left
at the server's default: off on MySQL 5.6 and MariaDB, on (30-day expiry) on MySQL 8+. To turn it on
for 5.6, in `openmrs-db.env`:

```bash
OPENMRS_DB_OPT_log_bin='mysql-bin'
OPENMRS_DB_OPT_server_id='1'
OPENMRS_DB_OPT_binlog_format='ROW'
OPENMRS_DB_OPT_expire_logs_days='10'            # MySQL 8+ / MariaDB 10.6+: binlog_expire_logs_seconds
```

To turn it off again, run [`purge-binlogs`](../../docs/utilities.md) first, then remove those lines
(or, on MySQL 8+, add `OPENMRS_DB_OPT_skip_log_bin=''`) and run `pihx <name> start`: once binary
logging is off, the server can't delete the binlogs it already has.

## MySQL accounts

`openmrs-db-accounts` runs on every `start` and `update`, and first for any service that depends on
it. It makes sure each account declared for it exists:

```
OPENMRS_DB_ACCOUNT_<ID>_USER='<user>'
OPENMRS_DB_ACCOUNT_<ID>_PASSWORD='<password>'
OPENMRS_DB_ACCOUNT_<ID>_GRANTS='<privileges> ON <db>.<table>[;<privileges> ON <db>.<table>...]'
OPENMRS_DB_ACCOUNT_<ID>_DATABASES='<db> ...'   # optional: created if missing
```

It creates `<user>@'%'` if missing, sets its password to the declared one (so a rotated password, or
a restored database's old one, is replaced), creates the databases and applies the grants. A
declaration missing a value changes nothing; anything else wrong fails with MySQL's own error. Either
way its log (`pihx <name> logs openmrs-db-accounts`) says why. Accounts that aren't declared, and the
same user's accounts for other hosts, are left alone: removing one is up to you. `root` and the
OpenMRS account (`OPENMRS_DB_USER`) can't be declared: their passwords are the instance's own
(`OPENMRS_DB_*`). If it fails, so do `start` and `update`, naming it, and a lock-holding `run-service`
(petl) doesn't run.

A service's account belongs in that service's own `with-openmrs-db.yaml`, from values in its own env
file, as [petl's](../petl/with-openmrs-db.yaml) is: only `openmrs-db-accounts` sees it, and changing
it leaves the database running. An account declared directly in `openmrs-db.env` also reaches the
database container (which reads that file), so changing one recreates `openmrs-db` on the next
`start`/`update`.

## Changing the passwords

`OPENMRS_DB_PASSWORD` can't contain a backslash, and neither can `OPENMRS_DB_ROOT_PASSWORD` with a
MySQL image: the MySQL images' first setup and openmrs-core's first install store it wrongly, so
`openmrs-db` refuses one before setting up an empty data directory (MariaDB's images handle it in
the root password).

Changing either password in `openmrs-db.env` changes nothing by itself: MySQL takes them only when
it sets up an empty data directory, and OpenMRS (core 2.6+) keeps the connection settings its
runtime properties file got on its first start. After editing the file, run:

```bash
pihx <name> openmrs-db reset-accounts
```

It stops the instance, sets the MySQL accounts to the passwords in the instance's files (with
`reset-mysql-accounts`), sets `connection.username` and `connection.password` in
`openmrs-runtime.properties` in `openmrs-data` (keeping the previous file as
`openmrs-runtime.properties.bak`, which still holds the old password), and starts it again. Until it
runs, the database reports unhealthy: its healthcheck already uses the new password.

## Restoring and summarizing

`initialize` restores the database from the entries `openmrs-db.sql[.gz|.7z|.zip]`,
`openmrs-db.percona*` or `openmrs-db.datadir/` ([Initializing an instance](../../docs/restore.md)).
After a physical restore the source's accounts are reset to the instance's.
`pihx <name> summary` prints the database's sections, from the running container or, with the
instance stopped, from its volume.
