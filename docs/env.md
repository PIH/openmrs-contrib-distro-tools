# An instance's env file

Each instance's settings are in `$OPENMRS_DOCKER_HOME/<name>/env`, which `create` writes (puppet
writes it for the instances it manages).

## Format

Each line is `KEY='value'`. bash sources the file and Docker Compose reads it, and a single-quoted
value is literal to both, so passwords can contain `$`, `"`, backticks and backslashes. A value can't
contain a single quote or a newline: `create` and `add-service` refuse one, naming the variable. If
you edit `env` by hand, keep to single quotes (a double-quoted value is expanded by bash and by
Compose, differently).

## Where values come from

- **Defaults** are only in `.env.defaults` files: `docker/instance.env.defaults` for the instance
  itself (`TZ`, `DISTRO_SOURCE_DIR`, `SEED_IMAGE_*`), and `docker/services/<svc>.env.defaults` for each
  service. The fragments require their variables (`${VAR?}`) rather than repeating a default.
- **`create`** writes each of them, taking a value already set in your shell instead of its default.
  A variable with no usable default (e.g. `PETL_MYSQL_PASSWORD`) has to be set, or `create` and
  `add-service` refuse.
- **`sync`** adds any variable the instance's fragments now require that `env` lacks, with its
  default. Until then, every other command refuses, naming it.
- **When a command runs**, `env` is sourced and wins over your shell. A variable meant only for one
  run (`RESTORE_*_PATH` for `initialize`, `SMOKE_TESTS_OUTPUT_DIR`, ...) must therefore stay out of
  `env`: set it on the command line.

## What reaches the containers

Containers don't get the whole file. A service whose container takes variables from `env` declares
their name prefixes in its `.env.defaults`, as a `# container-env: PREFIX_ ...` line: `OMRS_` for
openmrs (`OMRS_EXTRA_*` runtime properties, `OMRS_JAVA_SERVER_OPTS`), `OPENMRS_DB_OPT_` for
openmrs-db, `PETL_`, `DATASOURCES_`, `SPRING_` and `LOGGING_` for petl, `SQLSERVER_LOGIN_` for
sqlserver-setup. Another container in the same fragment gets its own file from a
`# container-env <file>: PREFIX_ ...` line (`<file>.env`): openmrs-db-accounts gets the
`OPENMRS_DB_ACCOUNT_` lines that way, so changing an account doesn't recreate (restart) openmrs-db. On every command, `openmrs-docker` copies the matching lines of `env` into `<svc>.env`
(mode 600) in the instance directory, which is that fragment's `env_file`. Without the directive
nothing from `env` is passed: the container gets only what its fragment names under `environment:`,
which is how every secret it needs (DB passwords, OpenHIM and mediator settings) reaches it. Edit
`env`, not the generated files.

A `# run-service: holds-lock` line in a service's `.env.defaults` makes `run-service` hold the
instance's lock for that service's runs ([One command at a time](instances.md#one-command-at-a-time));
petl has it. A `# setup-services: <svc> ...` line names a fragment's one-shot setup services
(`openmrs-db-accounts`, `sqlserver-setup`): `start` and `update` wait for them and fail, naming the
one that didn't succeed, and `run-service` runs them first and doesn't run the service if one fails.

## Variables

| Variable | Required? | Purpose |
|---|---|---|
| `OPENMRS_IMAGE_NAME` | Required | OpenMRS image, no tag |
| `OPENMRS_PIH_CONFIG` | Optional | PIH config profile, for a distro that uses one; OpenMRS fails at startup if it needs one and this is missing |
| `DISTRO_SOURCE_DIR` | For `build`, `--dev` and `--build` | Path to the distro repo checkout |
| `SEED_IMAGE_NAME` | For `initialize`, unless each volume has a `RESTORE_*` source ([Initializing an instance](restore.md)) | Seed image, no tag |
| `OPENMRS_DATA_OWNER` | Optional (the openmrs image's runtime `uid:gid`) | Owner `initialize` gives a restored `openmrs-data` |
| `OPENMRS_CREATE_TABLES` | Optional (`true`) | Whether OpenMRS creates its schema on first start; `initialize` sets it to `false` when the database is restored without runtime properties |
| `SERVICE_NAME` | Optional (the instance name) | Docker Compose project name |
| `OPENMRS_IMAGE_TAG`, `SEED_IMAGE_TAG` | Optional (`latest`) | Image tags |
| `OPENMRS_HTTP_PORT`, `OPENMRS_DB_PORT`, `OPENMRS_DEBUG_PORT` | Optional | Published ports; set them differently to run more than one instance at once |
| `TZ` | Optional (`UTC`) | Containers' time zone |
| `OPENMRS_DB_IMAGE_NAME` (`mysql`), `OPENMRS_DB_IMAGE_TAG` (`5.6`), `OPENMRS_DB_USER`, `OPENMRS_DB_PASSWORD`, `OPENMRS_DB_ROOT_PASSWORD`, `OPENMRS_ACTIVITYLOG_ENABLED`, `OPENMRS_DB_MEMORY_LIMIT`, `OPENMRS_MEMORY_LIMIT`, `OPENMRS_JAVA_MEMORY_OPTS` | Optional | Database and memory settings. The DB passwords can't contain a backslash |
| `OPENMRS_DB_OPT_<option>` | Optional | MySQL/MariaDB server options ([below](#database-server-options-openmrs_db_opt_)) |
| `SERVICES` | Optional (`openmrs-db,openmrs`), at `create` | The fragments in `docker/services/` to copy into the instance |
| `OMRS_EXTRA_*` | Optional | Extra OpenMRS runtime properties, taken from your shell at `create` ([below](#runtime-properties-omrs_extra_)) |
| `OPENMRS_DB_ACCOUNT_<ID>_*` | Optional | MySQL accounts that openmrs-db-accounts makes sure exist ([MySQL accounts](services.md#mysql-accounts)) |
| `OPENMRS_DOCKER_LOCK_WAIT` | Optional (`0`), in your shell, not `env` | Seconds a command waits for another one holding the instance's lock, instead of refusing at once ([One command at a time](instances.md#one-command-at-a-time)) |

The optional services' variables are in [Optional services](services.md).

## Database server options (`OPENMRS_DB_OPT_*`)

Each `OPENMRS_DB_OPT_<option>` variable becomes a `--<option>=<value>` flag on the
`mysqld`/`mariadbd` command line, with `_` in the name turned into `-` (MySQL and MariaDB treat the
two the same in option names). An empty value gives a bare flag: `OPENMRS_DB_OPT_skip_name_resolve=`
becomes `--skip-name-resolve`. An option not set is left at the server's own default, so the same
settings carry over to another MySQL or MariaDB version as long as each option exists there. To drop
one of the defaults below, delete its line from `env`.

`create` writes these defaults (from `docker/services/openmrs-db.env.defaults`), and takes any other
`OPENMRS_DB_OPT_*` set in your shell:

| Option | Default |
|---|---|
| `character_set_server` | `utf8` |
| `collation_server` | `utf8_general_ci` |
| `max_allowed_packet` | `1G` |
| `innodb_buffer_pool_size` | `1G` |
| `net_read_timeout`, `net_write_timeout` | `3600` |
| `log_bin_trust_function_creators` | `1` (only matters when binary logging is on, e.g. by default on MySQL 8+: lets PETL create functions) |

Binary logging, e.g. for a CDC tool such as Debezium, is left at the server's default: off on MySQL
5.6 and MariaDB, on (30-day expiry) on MySQL 8+. To turn it on for 5.6:

```bash
OPENMRS_DB_OPT_log_bin='mysql-bin'
OPENMRS_DB_OPT_server_id='1'
OPENMRS_DB_OPT_binlog_format='ROW'
OPENMRS_DB_OPT_expire_logs_days='10'            # MySQL 8+ / MariaDB 10.6+: binlog_expire_logs_seconds
```

To turn it off again, run [`purge-binlogs`](utilities.md) first, then remove those lines (or, on
MySQL 8+, add `OPENMRS_DB_OPT_skip_log_bin=`) and restart: once binary logging is off, the server
can't delete the binlogs it already has.

## Runtime properties (`OMRS_EXTRA_*`)

openmrs-core's `startup-init.sh` turns each `OMRS_EXTRA_<name>` into a runtime property: the name is
lowercased, `_` becomes `.` and `__` becomes `_` (so `OMRS_EXTRA_pihmalawi_warehouse_connection_url`
sets `pihmalawi.warehouse.connection.url`). Property keys with capital letters can't be set this way.

Distro images already set some of these: the OpenMRS SDK's `build-distro` bakes each `property.<key>`
from `openmrs-distro.properties` into the image as `ENV OMRS_EXTRA_<key with . replaced by _>`, e.g.
`OMRS_EXTRA_pih_config` and `OMRS_EXTRA_initializer_startup_load`. To override one of those, use
exactly that name, including its case. Environment variable names are case-sensitive, so
`OMRS_EXTRA_INITIALIZER_STARTUP_LOAD` would be a second variable for the same property rather than an
override, and on a first install openmrs-core keeps the image's value. Check an image's baked values
with `docker image inspect <image> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep OMRS_EXTRA_`.

openmrs-core 2.6+ writes the runtime properties file once, on its first install, and afterwards only
merges `OMRS_EXTRA_*` into it. For anything else in an existing file, see
[`runtime-properties`](utilities.md).
