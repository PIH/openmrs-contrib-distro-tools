# openmrs-contrib-distro-tools

Tooling for running OpenMRS distributions locally for development or testing, in CI, or on a production machine
Clone it once and use it as a shortcut for common `openmrs-docker` and `openmrs-sdk` workflows.

## Install

### On Linux or macOS

Clone this repo (change the target as appropriate for personal preference) and put its `bin/` directory on `PATH`:

```bash
export DISTRO_TOOLS_HOME=~/code/github/pih/openmrs-contrib-distro-tools  # Use whatever location you like to keep your code repositories
git clone https://github.com/PIH/openmrs-contrib-distro-tools.git $DISTRO_TOOLS_HOME
echo "export PATH=\"$DISTRO_TOOLS_HOME/bin:\$PATH\"" >> ~/.bashrc   # bash — use ~/.zshrc for zsh
```

Open a new terminal and `openmrs-docker`/`openmrs-sdk` are available directly.

### On Windows

**Step 1 — Install Windows Subsystem for Linux if not already installed**

Open PowerShell in administrator mode by right-clicking and selecting "Run as administrator" and
enter the following command:

```powershell
wsl --install
```

After this is completed, reboot your computer.

**Step 2 — Download the setup script and run it**

Open the Ubuntu terminal from your start menu and paste the following command:

```bash
curl -fsSL https://raw.githubusercontent.com/PIH/openmrs-contrib-distro-tools/main/docker/setup.sh | bash
```

When the process is complete, close the Ubuntu terminal window and relaunch it from the Start Menu.
You only need to do this once — `openmrs-contrib-distro-tools` is now installed and on your `PATH`.

## SDK (`openmrs-sdk`)

The `openmrs-sdk` command is a thin wrapper around the OpenMRS SDK itself.  It is not a replacement for the SDK but
rather a convenient way to run common commands.  One can choose to use it or choose to just use the SDK directly.
If choosing to use the SDK directly, inspecting the openmrs-sdk script will give you a good idea of what the
native commands should be.

The `openmrs-sdk` command should be invoked using the following syntax:

```bash
ENV1=VAL1 ENV2=VAL2 openmrs-sdk <command> <server-id>
```

The server ID is a name of your choosing — it controls the server directory (`~/openmrs/<server-id>`) and, by
default, the database name. It can also be set via the `SERVER_ID` environment variable instead of passed
positionally. Because `create`/`update`/`update-config` build from source, run `openmrs-sdk` from the root of the
distribution repo you want to build, or set `DISTRO_SOURCE_DIR` to point at it.

### `create`

Sets up a new SDK server: builds the distribution from source and runs the OpenMRS SDK setup wizard
non-interactively, producing a local Tomcat server backed by a MySQL database (by default, a Docker container
the SDK manages itself).  The following environment variables are supported by this command and should be set if any
of the listed defaults are not suitable for one's setup.

| Variable | Default | Purpose |
|---|---|---|
| `PIH_CONFIG` | _(optional)_ | PIH config profile passed to SDK setup, e.g. `<config>,<config>-<site>` — leave unset for a distro that doesn't use one; if it does and this is missing, OpenMRS setup fails, not this command |
| `DISTRO_SOURCE_DIR` | current directory | Path to the distro repo checkout to build |
| `SERVER_PORT` | `8080` | Tomcat HTTP port |
| `DEBUG_PORT` | `1044` | Remote debug port |
| `JAVA_HOME` | system Java | Java installation to use |
| `DB_CONTAINER` | _(SDK-managed — e.g. `openmrs-sdk-mysql-v8-4-1`)_ | Connect to an existing Docker MySQL container instead of letting the SDK create its own |
| `DB_HOST` | `localhost` | Database host (when `DB_CONTAINER` is set) |
| `DB_PORT` | `3306` | Database port (when `DB_CONTAINER` is set) |
| `DB_NAME` | server ID | Database name |
| `DB_USER` | `root` | Database user |
| `DB_PASSWORD` | `root` | Database password |

Pass the `--reset-db` flag to reset an already-existing database instead of keeping it.

The most common scenario is that one has their own MySQL Docker container running on their local machine, where they
managed their own databases, and do not have the SDK create these directly.  In this case, one needs to specify the
`DB_CONTAINER` environment variable to point to the container, and any other thoe other `DB_*` variables if the defaults
do not match one's setup.

Running from the root of this the distribution repository:

```bash
PIH_CONFIG=<specific-pih-config-setting-to-use> \
DB_CONTAINER=<my-mysql-container-name> \
DB_PORT=<my-mysql-container-port> \> \
DB_USER=root \
DB_PASSWORD=<my-mysql-root-password> \
openmrs-sdk create <server-id>
```

### `update`

Rebuilds the content package and distribution from source and redeploys the updated artifacts to an existing server.

| Variable | Default | Purpose |
|---|---|---|
| `DISTRO_SOURCE_DIR` | current directory | Path to the distro repo checkout to build |

```bash
openmrs-sdk update <server-id>
```

### `update-config`

Same as `update`, but builds and deploys content/configuration only, skipping the full distribution build.
This is intended to be fast to allow for rapid iteration and testing of content changes.

| Variable | Default | Purpose |
|---|---|---|
| `DISTRO_SOURCE_DIR` | current directory | Path to the distro repo checkout to build |

```bash
openmrs-sdk update-config <server-id>
```

NOTE: This will not automatically include updates made to openmrs-config-pihemr.  One first needs to run a `mvn clean install` 
on that project before running this command to incorporate any local changes made to that project.  One could combine these commands
as follows, assuming the openmrs-config-pihemr project is checked out in the same directory as the distribution repo:

```bash
mvn clean install -f ../openmrs-config-pihemr/pom.xml && openmrs-sdk update-config <server-id>
```

### `run`

Starts the server (Ctrl+C to stop).

| Variable | Default | Purpose |
|---|---|---|
| `JMX_PORT` | _(disabled)_ | Enable JMX remote monitoring on this port |

```bash
openmrs-sdk run <server-id>
```

### `destroy`

Deletes the server directory and drops its database. You will be prompted to confirm first.

| Variable | Default | Purpose |
|---|---|---|
| `DB_CONTAINER` | _(SDK-managed — e.g. `openmrs-sdk-mysql-v8-4-1`)_ | Drop the database from this existing Docker MySQL container instead of the default one |
| `DB_NAME` | server ID | Database name |
| `DB_USER` | `root` | Database user |
| `DB_PASSWORD` | `root` | Database password |

```bash
openmrs-sdk destroy <server-id>
```

For specific, ready-to-use examples of these commands, see the individual distribution README files.

## Docker (`openmrs-docker`)

### Creating a server instance

Each distribution has its own published Docker image, and (if it uses one) its own set of supported
PIH config profiles. Refer to the distribution-specific README files for these specific options.
Choose the options that best meet your needs for the type of environment you are setting up:

`OPENMRS_IMAGE_NAME` (eg. `partnersinhealth/lesotho-emr`)
`OPENMRS_PIH_CONFIG` (eg. `lesotho,lesotho-kol-ci`)

`OPENMRS_IMAGE_NAME` is the bare minimum required to create an instance that includes the `openmrs`
service, which is part of the default `SERVICES` value — so it's required unless you override
`SERVICES=` to exclude it (see "Adding OpenHIM and mediators" below). `OPENMRS_PIH_CONFIG` is
optional: not every distro uses a PIH config profile, and this tool has no way to know whether the
one you're creating an instance for does. If it does and you leave this unset, OpenMRS itself will
fail to start rather than `create` failing up front — set it when you know the distro needs it. For
additional configuration options, consult the usage documentation by running `openmrs-docker` with
no arguments.

For example, you can specify a different port for the Tomcat HTTP server by setting the `OPENMRS_HTTP_PORT` environment variable:

**For developers**:  In order for some options to be available that support deployment of uncommited distribution changes, you should also
set the `DISTRO_SOURCE_DIR` environment variable to the path of the distribution you want to use for local builds.

Once you have the appropriate environment variables determined, you pass them to the `openmrs-docker create` command along
with the name of the instance you want to create. The name is also the instance's Docker Compose project name, so it
must be lowercase letters, digits, `-` and `_`, starting with a letter or digit:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci \
DISTRO_SOURCE_DIR="<path_to_lesotho_emr_src>" \
openmrs-docker create <name>
openmrs-docker <name> start --build
```

Every setting `create` writes falls back to a default only if it isn't already set in your shell —
so you can override any of them the same way, including by sourcing your own settings file first.
That file needs to `export` each variable — plain `KEY=value` lines only set shell variables, which
child processes (like `openmrs-docker`) never see:

```bash
# kol-ci.sh
export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
export OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci
export OPENMRS_HTTP_PORT=9090
```

```bash
source kol-ci.sh
openmrs-docker create <name>
```

To reuse one of the tool's own generated `env` files as a starting point instead, wrap the
`source` in `set -a`/`set +a` — those files use plain `KEY='value'` lines (no `export`), since they
also have to work as a Docker Compose `--env-file`:

```bash
set -a; source ~/openmrs/other-instance/env; set +a
openmrs-docker create <name>
```

Creating a new instance will create a new directory under `$OPENMRS_DOCKER_HOME` on your machine (defaults to `$HOME/openmrs`)
containing the environment configuration and a pre-initialized Docker image.  If you wish to keep your docker instance directories
separate from your openmrs-sdk instance directories, you can set the `$OPENMRS_DOCKER_HOME` environment variable to a different location.

## `env` file reference

Each line is `KEY='value'`. bash sources the file and Docker Compose reads it, and a single-quoted
value is literal to both, so passwords can contain `$`, `"`, backticks and backslashes. A value can't
contain a single quote or a newline: `create` and `add-service` refuse one, naming the variable. If
you edit `env` by hand, keep to single quotes (a double-quoted value is expanded by bash and by
Compose, differently).

Containers don't get the whole file. A service whose container takes variables from `env` declares
their name prefixes in its `docker/services/<svc>.env.defaults`, as a `# container-env: PREFIX_ ...`
line: `OMRS_` for openmrs (`OMRS_EXTRA_*` runtime properties, `OMRS_JAVA_SERVER_OPTS`),
`OPENMRS_DB_OPT_` for openmrs-db. On every command, `openmrs-docker` copies the matching lines of
`env` into `<svc>.env` (mode 600) in the instance directory, which is that fragment's `env_file`.
Without the directive nothing from `env` is passed: the container gets only what its fragment names
under `environment:`, which is how every secret it needs (DB passwords, OpenHIM and mediator
settings) reaches it. Edit `env`, not the generated files. An instance created before this change
keeps its copied fragments, which pass the whole of `env` to the openmrs and openmrs-db containers,
until `openmrs-docker <name> sync`.

| Variable | Required? | Purpose |
|---|---|---|
| `OPENMRS_IMAGE_NAME` | Required | OpenMRS image, no tag |
| `OPENMRS_PIH_CONFIG` | Optional | PIH config profile for this instance — leave unset if the distro doesn't use one; OpenMRS fails at startup if it does and this is missing |
| `DISTRO_SOURCE_DIR` | Required for `build`/`--dev`/`--build` only | Path to the distro repo checkout |
| `SEED_IMAGE_NAME` | Required for `initialize` unless a `RESTORE_MYSQL_*`/`RESTORE_OPENMRS_DATA_PATH` source is given for every volume (see "Initializing a server" below) | Full seed image name (no tag) |
| `OPENMRS_DATA_OWNER` | Optional (the openmrs image's runtime `uid:gid`) | Owner `initialize` gives a restored `openmrs-data` -- see "Initializing a server" below |
| `OPENMRS_CREATE_TABLES` | Optional (`true`; `initialize` sets it to `false` automatically when relevant, see below) | Whether OpenMRS builds its schema from scratch on first boot |
| `SERVICE_NAME` | Optional (defaults to the instance name) | Docker Compose project name |
| `OPENMRS_IMAGE_TAG`, `SEED_IMAGE_TAG` | Optional (`latest`) | Image tags |
| `OPENMRS_HTTP_PORT`, `OPENMRS_DB_PORT`, `OPENMRS_DEBUG_PORT` | Optional | Port overrides — set differently per instance to run more than one at once |
| `TZ` | Optional (`UTC`) | Container timezone |
| `OPENMRS_DB_IMAGE_NAME` (`mysql`), `OPENMRS_DB_IMAGE_TAG` (`5.6`), `OPENMRS_DB_USER`, `OPENMRS_DB_PASSWORD`, `OPENMRS_DB_ROOT_PASSWORD`, `OPENMRS_ACTIVITYLOG_ENABLED`, `OPENMRS_DB_MEMORY_LIMIT`, `OPENMRS_MEMORY_LIMIT`, `OPENMRS_JAVA_MEMORY_OPTS` | Optional | Tuning knobs |
| `OPENMRS_DB_OPT_<option>` | Optional | MySQL/MariaDB server options -- see "Database server options" below |
| `SERVICES` | Optional (`openmrs-db,openmrs`) | Comma-separated canonical fragments to copy into the instance at `create` time — see `docker/services/` |
| `OMRS_EXTRA_*` | Optional | Extra OpenMRS runtime properties, captured from the calling shell at `create` time and passed through to the openmrs container (as are other `OMRS_*` image variables such as `OMRS_JAVA_SERVER_OPTS`) — see below |

#### Database server options via `OPENMRS_DB_OPT_*`

Each `OPENMRS_DB_OPT_<option>` variable in the env file becomes a `--<option>=<value>` flag on the
`mysqld`/`mariadbd` command line, with `_` in the name turned into `-` (MySQL and MariaDB treat the
two the same in option names). An empty value gives a bare flag: `OPENMRS_DB_OPT_skip_name_resolve=`
becomes `--skip-name-resolve`. Any option not set is left at the server's own default, so the same
settings carry over to a different MySQL or MariaDB version as long as each option exists there. To
drop one of the defaults below, delete its line from the env file.

`create` writes these defaults (from `docker/services/openmrs-db.env.defaults`), and captures any
other `OPENMRS_DB_OPT_*` set in the calling shell:

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

To turn it off again, run `purge-binlogs` first (see Utilities), then remove those lines (or, on
MySQL 8+, add `OPENMRS_DB_OPT_skip_log_bin=`) and restart: once binary logging is off, the server
can't delete the binlogs it already has.

#### Runtime properties via `OMRS_EXTRA_*`

openmrs-core's `startup-init.sh` turns each `OMRS_EXTRA_<name>` into a runtime property: the name is
lowercased, `_` becomes `.` and `__` becomes `_` (so `OMRS_EXTRA_pihmalawi_warehouse_connection_url`
sets `pihmalawi.warehouse.connection.url`). Property keys containing capital letters can't be set this
way.

Distro images already set some of these: the OpenMRS SDK's `build-distro` bakes each `property.<key>`
from `openmrs-distro.properties` into the image as `ENV OMRS_EXTRA_<key with . replaced by _>`, e.g.
`OMRS_EXTRA_pih_config` and `OMRS_EXTRA_initializer_startup_load`. To override one of those, use
exactly that name, including its case. Environment variable names are case-sensitive, so
`OMRS_EXTRA_INITIALIZER_STARTUP_LOAD` would be a second variable for the same property rather than an
override, and on a first install openmrs-core keeps the image's value. Check an image's baked values
with `docker image inspect <image> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep OMRS_EXTRA_`.

### Initializing a server

If you have never started the server before, you can dramatically speed up the initial startup
process by initializing the database and application data first, rather than letting OpenMRS build
them up from an empty state on its own:

```bash
openmrs-docker <name> initialize
```

NOTE: This command is only supported immediately after the instance is created. If it has
previously been started, this command will fail so as not to overwrite any existing data.

`initialize` populates two volumes -- `mysql/db-data` and `openmrs-data` -- and each one's *source*
is chosen independently, so e.g. the database can be restored from a real backup while
`openmrs-data` still comes from the nightly seed image, or vice versa. By default (nothing set but
`SEED_IMAGE_NAME`) both volumes come from that seed image, same as before. Setting one of the
`RESTORE_*` variables below overrides just that one volume's source for this `initialize`
invocation only (these aren't persisted to the instance's env file the way `SEED_IMAGE_NAME` is):

| Env var | Populates | Source |
|---|---|---|
| `SEED_IMAGE_NAME` / `SEED_IMAGE_TAG` | either, if not overridden | the nightly seed image (documented per-distro) |
| `RESTORE_MYSQL_DUMP_PATH` | `mysql/db-data` | a `.sql`/`.sql.gz` dump, handed to MySQL's own first-boot import -- or a `.7z`/`.zip` archive holding one (e.g. from `backup-mysqldump`), extracted into a temporary volume without touching the host's disk (`ARCHIVE_PASSWORD` for a protected archive) |
| `RESTORE_MYSQL_DATA_PATH` | `mysql/db-data` | a ready MySQL data directory, copied straight into the volume before MySQL ever starts (far faster for a large database) |
| `RESTORE_MYSQL_PERCONA_PATH` | `mysql/db-data` | a Percona/xtrabackup backup: a `.7z`/`.zip`/`.tar.gz`/`.tgz`/`.tar` archive (e.g. a legacy nightly `percona.7z`, or `backup-percona --output=<name>.7z`; `ARCHIVE_PASSWORD` for a protected one) or a directory. Extracted, prepared if it isn't already, and copied into the volume, all in containers -- see below |
| `RESTORE_OPENMRS_DATA_PATH` | `openmrs-data` | a directory, copied straight into the volume -- or a `.tar.gz`/`.tgz`/`.tar`/`.7z`/`.zip` archive of one (e.g. from `backup-openmrs-data-directory`), extracted straight into the volume without touching the host's disk (`ARCHIVE_PASSWORD` for a protected `.7z`/`.zip`) |

`initialize` waits up to `INITIALIZE_DB_TIMEOUT` seconds (default 3600) for the restored database to
become healthy -- a large dump import, or crash recovery of a large physical restore, can
legitimately take a long time. Like the `RESTORE_*` variables, it's set on the `initialize`
invocation itself.

`mysql/db-data` requires exactly one source: `RESTORE_MYSQL_DUMP_PATH`, `RESTORE_MYSQL_DATA_PATH`,
`RESTORE_MYSQL_PERCONA_PATH`, or `SEED_IMAGE_NAME`. `openmrs-data` is optional -- if neither `RESTORE_OPENMRS_DATA_PATH` nor
`SEED_IMAGE_NAME` is set, that volume is simply left for OpenMRS's own first-boot
module-initializer run to build up from scratch, same as a totally fresh install (e.g. when
restoring a real database backup with no matching `openmrs-data` backup to go with it).

When `openmrs-data` is restored from `RESTORE_OPENMRS_DATA_PATH`, `initialize` moves any restored
`openmrs-runtime.properties` aside to `openmrs-runtime.properties.restored`. It holds the source
server's connection settings, and openmrs-core 2.6+ only merges `OMRS_EXTRA_*` properties into an
existing runtime properties file, so those stale `connection.*` values would otherwise win over this
instance's. OpenMRS writes a fresh one from the instance's `env` on first start.

#### Carrying over runtime properties from the restored server

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
`openmrs-runtime.properties` and add
`-v /path/to/that/copy:/data/openmrs-runtime.properties.restored:ro` to the command.

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

`OMRS_EXTRA_*` values are merged into the runtime properties file on every start, overriding it (see
"Runtime properties via `OMRS_EXTRA_*`" above); removing one later leaves its last value in the file.
On an instance whose `env` is managed by puppet (mirebalais-puppet's `openmrs_docker` module), set
them with the module's `runtime_properties` / `java_system_properties` instead: puppet rewrites
`env` on every apply. Once you've finished comparing, delete `openmrs-runtime.properties.restored`
(it holds the source's secrets).

In that case, and when `openmrs-data` isn't restored or seeded at all, `initialize` also adds
`OPENMRS_CREATE_TABLES=false` to the instance's `env` file (unless already set) -- otherwise OpenMRS
finds no runtime properties in `openmrs-data`, assumes a fresh install, and tries to `CREATE TABLE`
everything from scratch against a database that already has that schema.

Files restored from `RESTORE_OPENMRS_DATA_PATH` keep the owners they had on the source host, so
`initialize` then changes the owner of everything in `openmrs-data` to the openmrs image's runtime
user (read from the image with `id`, e.g. `1001:0` for PIH's images). Set `OPENMRS_DATA_OWNER=<uid>:<gid>`
to choose it explicitly instead.

```bash
# restore the database from a logical dump, but still seed openmrs-data from the nightly image
RESTORE_MYSQL_DUMP_PATH=/path/to/backup.sql.gz SEED_IMAGE_NAME=... openmrs-docker <name> initialize

# restore both volumes from real backups, no seed image involved at all
RESTORE_MYSQL_DATA_PATH=/path/to/datadir RESTORE_OPENMRS_DATA_PATH=/path/to/data-dir openmrs-docker <name> initialize

# restore only the database from a backup; let openmrs-data build up fresh
RESTORE_MYSQL_DATA_PATH=/path/to/datadir openmrs-docker <name> initialize

# restore both volumes straight from backup-mysqldump / backup-openmrs-data-directory archives
ARCHIVE_PASSWORD=<password> RESTORE_MYSQL_DUMP_PATH=/path/to/backup.sql.7z RESTORE_OPENMRS_DATA_PATH=/path/to/openmrs-data.7z openmrs-docker <name> initialize
```

If an openmrs-data archive has exactly one top-level directory (as `backup-openmrs-data-directory`
produces), that directory's contents become `openmrs-data`; otherwise the archive's top level is used
as is. A dump archive must hold exactly one dump file (`.sql` or `.sql.gz`).

`RESTORE_MYSQL_PERCONA_PATH` takes a Percona/xtrabackup backup as it is. In a temporary
`percona-staging` volume, `initialize` extracts the archive (or copies the directory), unwrapping a
single top-level folder, so both a flat legacy `percona.7z` and an archive holding one
`<name>-percona/` folder work. It then runs `innobackupex --apply-log` if the backup isn't prepared
yet (legacy nightly backups are), copies it into `db-data` with `--copy-back`, and removes the
staging volume. Nothing is written to the host unencrypted, and it needs about twice the database's
size on Docker's volumes. Anything without an `xtrabackup_checkpoints` file is refused:

```bash
ARCHIVE_PASSWORD=<password> RESTORE_MYSQL_PERCONA_PATH=/path/to/percona.7z openmrs-docker <name> initialize
```

`RESTORE_MYSQL_DATA_PATH` is a plain, ready-to-use MySQL data directory instead. To make one from a
Percona backup by hand (e.g. to inspect it first), use the standalone scripts in `utils/` (see
below):

`openmrs-utils <script-name> [args...]` is on `PATH` (see "Install" above) and is a thin passthrough
to `$DISTRO_TOOLS_HOME/utils/<script-name>.sh` -- so `openmrs-utils extract-archive --path=...` is
exactly equivalent to running that script by its full path:

```bash
# a percona/xtrabackup backup: extract the archive, then convert it into a ready datadir
BACKUP_DIR=$(openmrs-utils extract-archive --path=/path/to/backup.7z --output-dir=./backup)
DATADIR=$(openmrs-utils convert-percona-backup --backup-dir="$BACKUP_DIR" --output-dir=./datadir)
RESTORE_MYSQL_DATA_PATH="$DATADIR" openmrs-docker <name> initialize
```

**Checking a restore:** `openmrs-utils fingerprint` (see Utilities) of the source before the backup,
and `openmrs-docker <name> fingerprint` of the new instance after `initialize` and before its first
start, then `diff`. The instance command reads its stopped volumes with the instance's own database
image and `OPENMRS_DB_OPT_*` options, so `[server]` shows what the running instance will have. Expect
`[accounts]` to differ, a physical restore to bring along other databases the source had, and
`[server]` to differ only where the two servers are configured differently:

```bash
openmrs-utils fingerprint --container=<source db container> --data-dir=<source data dir> --output=before.txt
openmrs-docker <name> fingerprint --data-dir --exclude-distribution-artifacts --output=after.txt
diff before.txt after.txt
```

**Disk space:** before creating any volume, `initialize` estimates what the restore will write and
stops if Docker's volume filesystem has less free than that plus 10%, rather than failing part way
with half-filled volumes. The estimate is a data directory's size, a dump's uncompressed size
(counted twice for a `.7z`/`.zip`, which is extracted into a temporary volume first), a Percona
backup's (counted twice: extracted, then copied in), and an
openmrs-data directory's or archive's uncompressed size; a seed image isn't counted. A dump import
usually needs more than the dump itself (MySQL builds the indexes too), so for dumps this catches
"nowhere near enough" rather than a tight fit. `extract-archive`, `backup-percona`,
`convert-percona-backup` and `backup-openmrs-data-directory` check their output's filesystem the
same way. `SKIP_DISK_SPACE_CHECK=true` goes ahead anyway.

**Accounts after `RESTORE_MYSQL_DATA_PATH` or `RESTORE_MYSQL_PERCONA_PATH`:** a physical backup is a copy of the source server's
entire data directory, *including its `mysql` system tables*, so it arrives with the source's
accounts and passwords (the image only creates its own on an empty data directory). `initialize`
sets them to this instance's before the database first starts, with `reset-mysql-accounts` (see
Utilities): every `root` and `OPENMRS_DB_USER` account gets this instance's password,
`OPENMRS_DB_USER@'%'` (how the openmrs container connects) and `root@'%'` are created if missing,
and anonymous accounts are removed. The source's other accounts (e.g. PETL or backup users) are
kept, and `initialize` lists them so you can remove the ones you don't need. `OPENMRS_DB_IMAGE_TAG`
should still match the MySQL version the backup was taken from. `RESTORE_MYSQL_DUMP_PATH` isn't
affected: a logical dump doesn't carry the source's accounts.

### Utilities (`utils/`)

Standalone, general-purpose scripts in this tool's own `utils/` directory (not part of the
`openmrs-docker` CLI, and usable entirely on their own -- e.g. against a production server that was
never created via `openmrs-docker` at all). Named arguments for values; secrets (passwords) are
environment variables instead, and reach the tools inside containers by environment or stdin, so
they're on no command line: `ps` on the host shows the command lines of processes in containers too.
The one exception is `backup-mysqldump --output=<name>.7z`, which streams the dump into 7z on stdin,
so `ARCHIVE_PASSWORD` is on 7z's command line inside its container while the dump runs. Run via `openmrs-utils
<script-name> [args...]` (a thin passthrough to the script of that name under `utils/` -- see
"Install" above), or the script directly by its full path -- the two are equivalent. Run any script
with no arguments for its exact usage; run `openmrs-utils` with no arguments to list them all.
Progress and errors go to stderr, so stdout carries only a result a caller may capture (e.g.
`extract-archive`'s path). A backup refuses an output that already exists, and removes what it
started writing if it fails. The scripts share helpers in `utils/lib/`; `common.sh` there sets out
these conventions for anyone writing a new one.

`extract-archive`, `backup-percona`, `convert-percona-backup` and `backup-openmrs-data-directory`
check free disk space before writing anything, as `initialize` does (see "Disk space" below).

- **`extract-archive --path=<path> [--output-dir=<dir>]`** -- extracts a `.7z`/`.zip`/`.tar.gz`/
  `.tgz`/`.tar` archive (optional `ARCHIVE_PASSWORD` env var, `.7z`/`.zip` only) and prints the path
  to its single top-level entry, or, for a flat archive with several (e.g. a legacy `percona.7z`
  holding the backup's files directly), the directory it extracted into; prints `<path>` unchanged
  for anything else.
- **`fingerprint (--container=<name> | --host=<host> [--port=3306] | --db-volume=<volume or dir>
  [--image=mysql:5.6] [--server-opt=<flag>...]) [--database=openmrs] [--data-dir=<volume or dir>
  [--exclude-distribution-artifacts]] [--output=<file>]`** -- writes a sorted summary to `diff`
  before and after a restore: server settings, databases, every table's exact row count (`COUNT(*)`:
  minutes on a large `obs`), routines/triggers/views, the highest id and `date_created` on
  `encounter`/`obs`/`patient`/`person`/`users`, accounts (`user@host`), and with `--data-dir` the
  files and bytes per top-level folder. No row contents or secrets. `--container`/`--host` log in as
  root (`MYSQL_ROOT_PASSWORD`); `--db-volume` reads a *stopped* instance's `db-data` by starting its
  image on it with grants disabled and no networking, with any `--server-opt` flags -- the way to
  check a restore after `initialize`, before OpenMRS first starts (which changes Liquibase and
  scheduler tables). For an instance, `openmrs-docker <name> fingerprint` passes its image and
  server options.
- **`convert-percona-backup --backup-dir=<dir> --output-dir=<dir>`** -- converts an extracted,
  already-prepared (`--apply-log`'d) percona/xtrabackup backup directory into a ready-to-use MySQL
  data directory (`--copy-back`), suitable for `initialize`'s `RESTORE_MYSQL_DATA_PATH`.
- **`backup-mysqldump (--container=<name> | --host=<host> [--port=3306]) --output=<path>
  [--database=openmrs] [--user=root] [--strip-definers] [--client-image=mysql:5.6]`** -- dumps a
  MySQL database (`MYSQL_PASSWORD` env var), including routines and triggers. `--container` dumps
  from inside a running MySQL container; `--host` connects over TCP instead (e.g. `--host=127.0.0.1`
  for MySQL installed directly on a legacy host), running mysqldump from `--client-image` with host
  networking, so the host needs only docker. By default the dump is a faithful, unmodified copy;
  `--strip-definers` removes `DEFINER=` clauses as it streams (see `strip-mysqldump-definers`),
  so the result restores cleanly on a server that doesn't have the source's accounts. `--output`'s extension picks the format: `.sql` is
  plain SQL, `.gz` (e.g. `backup.sql.gz`) is gzip-compressed SQL, and `.7z` is a
  password-protected archive (`ARCHIVE_PASSWORD` env var, required), matching PIH's existing
  backup convention. A `.7z` holds a single SQL file named after the archive (`backup.sql.7z` and
  `backup.7z` both contain `backup.sql`), streamed straight in, never written to disk unencrypted;
  `.gz.7z` is rejected, since 7z already compresses. All three are usable directly as
  `initialize`'s `RESTORE_MYSQL_DUMP_PATH`.
- **`strip-mysqldump-definers --path=<dump.sql|dump.sql.gz> --output=<path>`** -- for an existing
  dump (for a new one, use `backup-mysqldump --strip-definers`): strips `DEFINER=`user`@`host`` clauses from routines/triggers/
  views into a new copy (the original is untouched), so a definer account that doesn't exist on
  the restore target doesn't cause a restored routine/trigger to fail at execution time.
- **`backup-percona (--container=<name> | --host=<host> [--port=3306]) --volume=<db data volume or
  host dir> --output=<dir | path.7z> [--databases=<list>]`** -- takes a prepared physical backup of
  a running MySQL server's data directory, as root (`MYSQL_ROOT_PASSWORD` env var). `--container`
  reaches a MySQL container through its network; `--host` connects over TCP with host networking,
  for a MySQL installed on the host (e.g. `--host=127.0.0.1 --volume=/var/lib/mysql` on a legacy
  server). `--volume` is the server's data directory, read directly. An `--output` ending in `.7z`
  is a password-protected archive (`ARCHIVE_PASSWORD` env var, required) in the legacy nightly
  `percona.7z` layout -- prepared, files at the top level, `-p` encryption -- for
  `RESTORE_MYSQL_PERCONA_PATH` or the DW refresh; the backup is taken in a temporary Docker volume
  and archived from there, so it's never on the host unencrypted. Any other `--output` is a
  directory, ready for `convert-percona-backup` or `RESTORE_MYSQL_PERCONA_PATH`. `--databases` (optional, space-separated) limits the
  backup to specific databases, passed through to innobackupex's own `--databases` option with the
  `mysql` and `performance_schema` system databases added (innobackupex backs up only exactly what's
  listed, and a data directory restored without `mysql` has no usable accounts); omit it to back up
  everything. A failed backup leaves no output directory behind.
- **`backup-openmrs-data-directory --volume=<openmrs-data volume or host dir> --output=<path>
  [--exclude-distribution-artifacts] [--allow-running]`** -- archives an OpenMRS application data
  directory (a named volume or an absolute host directory path). `--output` ending in
  `.tar.gz`/`.tgz` produces a plain gzip-compressed tar; ending in `.7z` produces a
  password-protected archive instead (`ARCHIVE_PASSWORD` env var, required). The archive holds a
  single top-level directory named after the archive (`malawi-data.tar.gz` contains `malawi-data/`).
  Pass the archive itself as `initialize`'s `RESTORE_OPENMRS_DATA_PATH`, or extract it first with
  `extract-archive` for a plain directory. Backs up the whole directory by default, same as the seed
  image build; `--exclude-distribution-artifacts` skips the contents of `modules/`, `owa/`,
  `configuration/` and `frontend/`, which OpenMRS re-copies from its image on every start, and
  `.openmrs-lib-cache`, which it rebuilds --
  smaller, and avoids restoring stale `.omod`s alongside a newer distro's. Refuses to run while a
  running container has the volume mounted (stop OpenMRS first for a consistent copy);
  `--allow-running` overrides that. `.7z` doesn't record file ownership; use `.tar.gz` if that
  matters.
- **`clear-configuration-checksums --volume=<openmrs-data volume>`** -- removes
  openmrs-module-initializer's cached `configuration_checksums` from a volume (refuses if a running
  container currently has it mounted), so the next start reprocesses all configuration from
  scratch rather than trusting checksums that may no longer reflect reality -- e.g. after loading a
  different database while keeping an existing `openmrs-data`.
- **`purge-binlogs (--container=<name> | --host=<host> [--port=3306]) [--user=root]
  [--client-image=mysql:5.6]`** -- has a MySQL or MariaDB server delete all its binary logs except
  the one it's writing (`MYSQL_PASSWORD` env var, for a user with `SUPER`/`BINLOG_ADMIN`, root by
  default), via its own `PURGE BINARY LOGS`. Run it before turning binary logging off:
  once binary logging is off the server can't purge them, and the files stay on disk. Prints the
  number and total size of binlogs before and after.
- **`reset-mysql-accounts --volume=<db data volume or host dir> [--image=mysql:5.6] [--user=openmrs]
  [--database=openmrs]`** -- sets a *stopped* MySQL/MariaDB data directory's accounts to new
  passwords (`MYSQL_ROOT_PASSWORD` and `MYSQL_PASSWORD` env vars) without knowing the current ones:
  starts `--image` on it with `--skip-grant-tables --skip-networking`, sets every `root@*` and
  `--user@*` password, creates `root@'%'` and `--user@'%'` (all privileges on `--database`) if
  missing, removes anonymous accounts, and lists the other accounts it kept. Refuses while a
  container is using the volume. Used by `initialize` after a physical restore and by
  `openmrs-docker <name> reset-openmrs-db-accounts`.
- **`wait-for-healthy --container=<name> [--timeout=<seconds>] [--fail-on-unhealthy=true|false]`**
  -- polls until a container reports healthy; fails fast on exited/dead/restarting or a container with no
  healthcheck, or times out.

### Starting a server

You can start up an existing server (whether it has been previously initialized or not) by running:

```bash
openmrs-docker <name> start
```

After running the start command, you can wait for the server to be ready to accept connections by running:

```bash
openmrs-docker <name> wait
```

When you see **OpenMRS is ready**, open a browser and go to **http://localhost:8080/openmrs** (or
whatever `OPENMRS_HTTP_PORT` that instance was created with, if not the default).

### Tailing the logs

```bash
openmrs-docker <name> logs
```

### Stopping

When you are done, stop the environment to free up memory. Your data is preserved and will be there
when you start again.

```bash
openmrs-docker <name> stop
```

To wipe all data and start completely fresh next time:

```bash
openmrs-docker <name> destroy
```

### One command at a time

Every command that changes an instance (`initialize`, `start`, `stop`, `restart`, `update`, `pull`,
`build`, `sync`, `add-service`, `remove-service`, `reset-openmrs-db-accounts`, `destroy`) holds a lock on
it until it exits, and refuses to run while another command holds it, naming that command:

```
error: <name> is busy: initialize (pid 12345, started 2026-09-30 11:39:19) -- run this again once that finishes.
```

So on a puppet-managed host, the `pull && start` puppet runs on every apply fails, and changes nothing,
while an `initialize` or `reset-openmrs-db-accounts` is in progress. `run-service` refuses while the
instance is busy, but doesn't hold the lock itself, so a long job doesn't block anything else.
`status`, `logs` and `wait` never wait for it; `status` shows the holder. The lock is released however
its holder exits, so there's nothing to clean up after a crash. It uses `flock(1)` (util-linux, on
every Linux host); where `flock` isn't installed (e.g. macOS), commands run unlocked.

### Changing the database passwords

`OPENMRS_DB_PASSWORD` can't contain a backslash, and neither can `OPENMRS_DB_ROOT_PASSWORD` with a MySQL
image: the MySQL images' first setup and openmrs-core's first install store it wrongly, so `openmrs-db`
refuses one before setting up an empty data directory (MariaDB's images handle it in the root password).

Changing `OPENMRS_DB_PASSWORD` or `OPENMRS_DB_ROOT_PASSWORD` in `env` on its own changes nothing:
MySQL only takes them when it first sets up an empty data directory, and OpenMRS (core 2.6+) keeps
the connection settings its runtime properties file got on its first start. After editing `env`, run:

```bash
openmrs-docker <name> reset-openmrs-db-accounts
```

It stops the instance, sets the MySQL accounts to the passwords in `env` (with
`reset-mysql-accounts`, see Utilities), sets `connection.username` and `connection.password` in
`openmrs-runtime.properties` in openmrs-data (keeping the previous file as
`openmrs-runtime.properties.bak`, which still holds the old password), and starts it again. Until it
runs, the database reports unhealthy: its healthcheck already uses the new password.

### Updating to the latest version

```bash
openmrs-docker <name> update
```

**Notes for developers:**  

To deploy local changes from your locally cloned distribution codebase (see `DISTRO_SOURCE_DIR` configured above),
you can pass the `--build` flag when running `update` or `start`

To start up the OpenMRS instance in development mode (which means running with debugging enabled and volume mounting whatever
was most recently built by maven locally in the `DISTRO_SOURCE_DIR/distro/target/distro/web` directory into the OpenMRS image),
you should pass the `--dev` flag when running `start` or `update`.

### Keeping the tool up to date and pinning to a specific version

Because this tool is simply installed by cloning it from github, you can keep it up to date by
running the following command in the same directory you cloned it into:

```bash
git pull
```

If you are running a particular distribution that needs to be locked on a specific version of this tool,
you can pin to a specific commit by running the following command:

```bash
git checkout <commit/branch/tag>
```

Because each server instance is created into its own directory, with its own copy of the docker-compose files, 
if this tool is updated and any of these are changed, the server instances do not automatically receive these changes.

When starting up a given instance by running `start` or `update`, if an existing instance's
copied fragments are now stale, the tool prints an advisory naming which services drifted — 
it never blocks or modifies anything on its own. 

You can run the sync command to bring the compose files up to date with the latest changes, before restarting the instance:
```bash
openmrs-docker <name> sync
openmrs-docker <name> start/update
```

`sync` also adds to the instance's `env` any variable the refreshed fragments require that `env`
doesn't have, with its default from `.env.defaults`, and prints the names it added. It never
changes a variable already in `env`, and doesn't re-add optional ones you deleted (e.g. an
`OPENMRS_DB_OPT_*` server option).

Compose recreates only the containers whose merged config actually changed.

### Troubleshooting in Windows

**"Permission denied when connecting to Docker" or similar error**
Close the Ubuntu terminal and reopen it from the Start Menu. The docker group change applied by the
setup script only takes effect in new sessions.

**OpenMRS runs very slowly or runs out of memory**
WSL2 limits how much memory it can use by default. Create or edit `C:\Users\<YourName>\.wslconfig`
with the following content, then restart WSL (`wsl --shutdown` in PowerShell):

```
[wsl2]
memory=8GB
```

## CI: reusable workflows

`.github/workflows/verify.yml` is a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn clean verify` against the calling repo's root `pom.xml` on Java 8/temurin. A distro repo consumes it with a thin caller:

```yaml
name: Verify PRs

on:
  pull_request:
  workflow_dispatch:

jobs:
  build:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/verify.yml@main
```

No secrets required.

`.github/workflows/release-to-sonatype.yml` is a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn release:prepare release:perform -Prelease` against the calling repo's root `pom.xml`. Requires the calling repo to define a `release` Maven profile that GPG-signs artifacts, plus a few other things the workflow silently depends on (see `openmrs-config-pihemr`'s root `pom.xml` for a reference that satisfies all of these):

- **`maven-gpg-plugin` >= 3.2.0, configured with `<signer>bc</signer>`.** The workflow passes the signing key via the `MAVEN_GPG_KEY` env var, which only the Bouncy Castle signer reads — the plugin's default signer expects a populated GPG keyring instead, and versions before 3.2.0 don't support `MAVEN_GPG_KEY` at all.
- **`<scm>` must use an HTTPS connection URL** (e.g. `scm:git:https://github.com/ORG/REPO.git`), not SSH. `release:perform` re-clones the repo via this URL, and only HTTPS picks up the credential `actions/checkout` persists into `.git/config` — an SSH `scm:git:git@github.com:...` URL has no credential configured and the clone fails.
- **`distributionManagement`/publishing must use server id `central`**, matching the `server-id: central` configured in the workflow's `setup-java` step.

Optionally builds and pushes a Docker image of the released version too, the same way `build-and-deploy-to-sonatype.yml` does for snapshots (below) — pass `image_name` to enable this; omit it for module repos with no distro to build (e.g. `openmrs-module-pihcore`, `openmrs-module-pihapps`). Since `release:perform` builds the release under `target/checkout` rather than the working copy's own `target/`, the Docker context is `target/checkout/distro/target/distro/web`, and the version tag is read from `target/checkout/pom.xml` rather than the (by-then-bumped-to-the-next-SNAPSHOT) working copy.

`release:prepare` bumps the working copy to the next SNAPSHOT and pushes that commit, but never deploys it — and that push doesn't trigger `build-and-deploy-to-sonatype.yml`'s `on: push` either, since it's pushed with the default `GITHUB_TOKEN` (GitHub's own loop-prevention means GITHUB_TOKEN-authored pushes never trigger other workflow runs). So this workflow deploys the next snapshot itself as a final step (Maven and, if `image_name` is set, Docker), rather than depending on that push to trigger anything.

A distro repo consumes it with a thin caller:

```yaml
name: Release new version

on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/release-to-sonatype.yml@main
    with:
      image_name: partnersinhealth/pihemr
    secrets: inherit
```

`permissions: contents: write` is required because `release:prepare` pushes commits and a tag to the default branch. In a reusable-workflow call, the effective token permissions are governed by the caller — a called workflow's own `permissions:` block can only narrow, never widen — so this must be declared here.

Requires `SONATYPE_USERNAME`, `SONATYPE_PASSWORD`, `SONATYPE_GPG_PASSPHRASE`, and `SONATYPE_GPG_PRIVATE_KEY` secrets available to the caller (passed via `secrets: inherit`); also `DOCKERHUB_PASSWORD` if `image_name` is set.

`.github/workflows/release-to-openmrs-jfrog.yml` is a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn release:prepare release:perform` (no signing profile) against the calling repo's root `pom.xml`, deploying to the OpenMRS JFrog `modules-pih`/`modules-pih-snapshots` repos instead of Sonatype Central. Unlike `release-to-sonatype.yml`, there's no GPG signing step and no requirement that dependencies be non-SNAPSHOT — JFrog doesn't enforce Central's "no SNAPSHOT dependencies in a release" rule. Requires the calling repo's root `pom.xml` to satisfy:

- **`maven-release-plugin` configured with `<allowTimestampedSnapshots>true</allowTimestampedSnapshots>`.** Without this, `release:prepare`'s own snapshot-dependency check fails the build on any SNAPSHOT dependency (the usual reason to use this workflow over `release-to-sonatype.yml` in the first place).
- **`<scm>` must use an HTTPS connection URL** (e.g. `scm:git:https://github.com/ORG/REPO.git`), not SSH, for the same re-clone-during-`release:perform` reason as `release-to-sonatype.yml` above.
- **`distributionManagement`/publishing must use server id `openmrs-repo-modules-pih`**, matching the `server-id: openmrs-repo-modules-pih` configured in the workflow's `setup-java` step (see `openmrs-module-pihcore`'s root `pom.xml` for a reference).

Optionally builds and pushes a Docker image of the released version too, the same way `build-and-deploy-to-openmrs-jfrog.yml` does for snapshots (below) — pass `image_name` to enable this; omit it for module repos with no distro to build (e.g. `openmrs-module-pihcore`, `openmrs-module-pihapps`). Since `release:perform` builds the release under `target/checkout` rather than the working copy's own `target/`, the Docker context is `target/checkout/distro/target/distro/web`, and the version tag is read from `target/checkout/pom.xml` rather than the (by-then-bumped-to-the-next-SNAPSHOT) working copy.

`release:prepare` bumps the working copy to the next SNAPSHOT and pushes that commit, but never deploys it — and that push doesn't trigger `build-and-deploy-to-openmrs-jfrog.yml`'s `on: push` either, since it's pushed with the default `GITHUB_TOKEN` (GitHub's own loop-prevention means GITHUB_TOKEN-authored pushes never trigger other workflow runs). So this workflow deploys the next snapshot itself as a final step (Maven and, if `image_name` is set, Docker), rather than depending on that push to trigger anything.

A distro repo consumes it with a thin caller:

```yaml
name: Release new version

on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/release-to-openmrs-jfrog.yml@main
    with:
      image_name: partnersinhealth/pihemr
    secrets: inherit
```

`permissions: contents: write` is required for the same reason as `release-to-sonatype.yml` above.

Requires `OPENMRS_MAVEN_USERNAME`, `OPENMRS_MAVEN_PASSWORD`, and `GHA_WRITE_TOKEN` secrets available to the caller (passed via `secrets: inherit`); also `DOCKERHUB_PASSWORD` if `image_name` is set.

`.github/workflows/build-and-deploy-to-openmrs-jfrog.yml` is a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn deploy` against the calling repo's root `pom.xml` on every push, deploying SNAPSHOT builds to the OpenMRS JFrog `modules-pih-snapshots` repo, then builds and pushes a Docker image of the result. This is the JFrog counterpart to `build-and-deploy-to-sonatype.yml` (which deploys SNAPSHOTs to Sonatype Central) — new callers should prefer this one, since mixing Sonatype for snapshots with JFrog for releases (or vice versa) just to shuffle credentials between the two is not worth the complexity; `build-and-deploy-to-sonatype.yml` remains only for repos that haven't migrated their release workflow off `release-to-sonatype.yml` yet. Requires the same `distributionManagement` server id (`openmrs-repo-modules-pih`) as `release-to-openmrs-jfrog.yml` above.

A distro repo consumes it with a thin caller:

```yaml
name: Build and deploy

on:
  push:
    branches: [master]
  workflow_dispatch:

jobs:
  build-and-publish:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/build-and-deploy-to-openmrs-jfrog.yml@main
    with:
      image_name: partnersinhealth/pihemr
      maven_profiles: distro-zip # only if the repo defines this profile
    secrets: inherit
```

Requires `OPENMRS_MAVEN_USERNAME`, `OPENMRS_MAVEN_PASSWORD`, and `DOCKERHUB_PASSWORD` secrets available to the caller (passed via `secrets: inherit`).

All four workflows above that build a Docker image (`build-and-deploy-to-sonatype.yml`, `build-and-deploy-to-openmrs-jfrog.yml`, `release-to-sonatype.yml`, `release-to-openmrs-jfrog.yml`) share the same QEMU/Buildx/login/build-push steps via the `.github/actions/build-and-push-docker` composite action, so that logic only needs to change in one place. Similarly, all four also share the same `mvn deploy` + version-extraction steps via `.github/actions/maven-deploy` — the two snapshot workflows use it for their one deploy, and the two release workflows use it a second time, after `release:prepare`/`release:perform`, to deploy the next development version (see above). Both are internal implementation details of those workflows, not something a distro repo calls directly.

### Base image variants

Each of those four workflows can also push additional tags of `image_name` built from the same distro on variants of the `openmrs/openmrs-core` base image — for example, on Java 8 to match production servers, while `latest` and the plain version tag stay on the default (Java 17) base image. Pass `image_variants`, one variant per line as `<tag suffix>=<base image variant>`; each is pushed as `latest-<suffix>` and `<version>-<suffix>`. The variant replaces the variant part of the base image tag the SDK chose, e.g. `amazoncorretto-8` turns `2.8.9` into `2.8.9-amazoncorretto-8`. Leave it empty after the `=` to use the plain base image tag instead — useful when the distro itself defaults to a variant (via `docker.image.javaVersion`). An instance switches to a variant by setting its `OPENMRS_IMAGE_TAG` (e.g. `latest-java8`):

```yaml
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/build-and-deploy-to-openmrs-jfrog.yml@main
    with:
      image_name: partnersinhealth/zl-emr
      image_variants: |
        java8=amazoncorretto-8
        java21=amazoncorretto-21
```

This relies on the SDK generating a Dockerfile with the base image tag's version and variant as separate build args (`ARG BASE_IMAGE_VERSION=...` and `ARG BASE_IMAGE_VARIANT=...`), added in [SDK-404](https://openmrs.atlassian.net/browse/SDK-404); the build fails with an explicit error if the Dockerfile doesn't have them. The SDK can only split the tag when the distro sets `docker.image.openmrsVersion`/`docker.image.javaVersion` (or neither) — if it sets a full `docker.image.tag`, that whole tag is the version and each variant is appended to it. Maven runs only once — every tag is built from the same Docker context. The variants are built one after another after the `latest` and version tags are pushed, and each is a full multi-arch build, so each one adds noticeably to the job's run time.

## Seed image builds

`.github/workflows/build-seeded-image.yml` is a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) — it builds a distro
from source, runs it, exports the database and data volume, packages them into a seed image, and
pushes it. A distro repo consumes it with a thin caller workflow, one job per site (no matrix — with
this much of the logic already shared, a matrix mostly just saves repeating `secrets: inherit`):

```yaml
name: Build seeded images
on:
  schedule:
    - cron: '0 2 * * *'
  workflow_dispatch:

jobs:
  kol-ci:
    if: github.repository_owner == 'PIH'
    concurrency:
      group: build-seeded-images-kol-ci-${{ github.ref }}
      cancel-in-progress: true
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/build-seeded-image.yml@main
    with:
      image_name: partnersinhealth/lesotho-emr
      pih_config: lesotho
    secrets: inherit
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | OpenMRS image, no tag |
| `pih_config` | Optional | PIH config profile to seed, for a distro that uses one. Also used (lowercased) as the instance name unless `instance_name` is set |
| `instance_name` | Optional | Instance/seed-name identifier. Defaults to `pih_config`, lowercased — required if the distro has no `pih_config` to default from |
| `seed_image_name` | Optional | Full seed image name, no tag. Defaults to `<image_name>-seed-<instance_name>` |

Requires a `DOCKERHUB_PASSWORD` secret available to the caller (passed via `secrets: inherit`).

## Smoke tests

`.github/workflows/execute-pihemr-smoke-tests.yml` is a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) — it creates an `openmrs-docker` instance, attaches the `openmrs-smoke-tests` service, initializes it from a site's seed image (for fast startup), waits for OpenMRS to be ready, then runs the smoke-tests image against it over the instance's own Compose network, uploads the results as a `smoke-test-results-<instance>` artifact (Maven's build/report output plus Selenium screenshots), and tears everything down. It validates the built image/config in isolation, not any persistent deployed server — no external network access or secrets beyond Docker Hub credentials are required. A distro repo consumes it with a thin caller workflow, one job per site:

```yaml
name: Smoke tests

on:
  workflow_dispatch:

jobs:
  kouka:
    if: github.repository_owner == 'PIH'
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/execute-pihemr-smoke-tests.yml@main
    with:
      image_name: partnersinhealth/pihliberia-emr
      instance_name: kouka
      pih_config: liberia,liberia-harper,liberia-harper-kouka
      seed_image_name: partnersinhealth/pihliberia-emr-seed-liberia
      suite: liberia
    secrets: inherit
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | OpenMRS image, no tag |
| `instance_name` | Required | Clean identifier for the `openmrs-docker` instance and artifact naming (e.g. the real CI server's own name, like `kouka` or `kgh-test`) — independent of `pih_config`, which may be a comma-separated chain that isn't a valid instance/image-tag name on its own |
| `pih_config` | Required | Full PIH config chain to test, matching what the site's real CI server actually runs (e.g. `liberia,liberia-harper,liberia-harper-kouka`) — check the site repo's own `<server>.env` file for the authoritative value, not just its `build-seeded-images.yml` base profile |
| `seed_image_name` | Required | Full seed image name, no tag — pass the exact value the corresponding `build-seeded-images.yml` job produces (with `pih_config` now potentially multi-value, there's no reliable way to derive this automatically) |
| `suite` | Required | Smoke-test suite passed to `execute-smoke-tests.sh`, independent of `pih_config` (e.g. `liberia`, `sierraleone`, `mexico`, `zlCentral`) |
| `admin_user_password` | Optional | Admin user password baked into this site's seed data. Defaults to the smoke-tests image's own default |
| `tools_ref` | Optional | Ref of `openmrs-contrib-distro-tools` to check out. Defaults to its default branch — only needed to validate a change to this workflow, or to `bin/openmrs-docker`/`docker/services`, from a branch before merging |

Requires a `DOCKERHUB_PASSWORD` secret available to the caller (passed via `secrets: inherit`).

### Running smoke tests locally

The `openmrs-smoke-tests` service is opt-in — it's not part of the default `openmrs-db,openmrs` set an instance creates with, so attach it explicitly:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/pihliberia-emr \
OPENMRS_PIH_CONFIG=liberia \
SEED_IMAGE_NAME=partnersinhealth/pihliberia-emr-seed-liberia \
openmrs-docker create myinstance

openmrs-docker myinstance add-service openmrs-smoke-tests
openmrs-docker myinstance initialize
openmrs-docker myinstance start
openmrs-docker myinstance wait
openmrs-docker myinstance run-service openmrs-smoke-tests ./execute-smoke-tests.sh liberia
```

Running `wait` before `run-service` matters: the `openmrs` container's own Docker healthcheck (which `depends_on: condition: service_healthy` in the smoke-tests fragment relies on) flips to "healthy" as soon as Tomcat responds — well before OpenMRS actually finishes starting up (see "Starting a server" above). `wait` polls the logs for the real completion signal instead, so running it first avoids the smoke tests hitting a half-started OpenMRS.

| Variable | Default | Purpose |
|---|---|---|
| `SMOKE_TESTS_OUTPUT_DIR` | `./smoke-test-output` | Host directory bind-mounted onto the container's Maven `target/` (build output, failsafe/surefire reports) |
| `SMOKE_TESTS_SCREENSHOTS_DIR` | `./smoke-test-screenshots` | Host directory bind-mounted onto the container's Selenium screenshot directory |
| `SMOKE_TESTS_ADMIN_PASSWORD` | image default (`Admin123`) | Admin password baked into this site's seed data |
| `SMOKE_TESTS_IMAGE_NAME`, `SMOKE_TESTS_IMAGE_TAG` | `partnersinhealth/pihemr-smoke-tests`, `latest` | Smoke-tests image to run |

Once done, tear the instance down with `openmrs-docker myinstance destroy --force`.

## Vulnerability scanning

`.github/workflows/scan-docker-image.yml` is a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs [Trivy](https://github.com/aquasecurity/trivy) against a published image and uploads the results as SARIF to the calling repo's own Security tab (Code scanning alerts). It's report-only — a scan that finds vulnerabilities never fails the caller's pipeline, only a scan-execution error (bad image ref, registry pull failure, etc.) does. A distro repo consumes it as a follow-up job after its build-and-push job:

```yaml
scan:
  needs: build-and-publish
  if: github.repository_owner == 'PIH'
  uses: PIH/openmrs-contrib-distro-tools/.github/workflows/scan-docker-image.yml@main
  with:
    image_name: partnersinhealth/lesotho-emr
  permissions:
    security-events: write
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | Docker Hub image name, no tag |
| `tag` | Optional | Tag to scan. Defaults to `latest` |

No secrets required — the images scanned here are public, so Trivy pulls them anonymously. The calling job must grant `permissions: security-events: write` itself; a called reusable workflow's `permissions:` block can only narrow what the caller grants, never widen it.

Findings only surface in the Security tab on **public** repos — that's a free GitHub feature there, but requires a GitHub Advanced Security license on a private repo.

## Adding OpenHIM and mediators

`SERVICES=<comma-separated>` (default `openmrs-db,openmrs`) selects which canonical fragments
under `docker/services/` get copied into a new instance — pass it to `create` to include the
standard OpenHIM install (`openhim`, i.e. mongo + openhim-core + openhim-console) and one or more
mediators alongside OpenMRS, or `add-service`/`remove-service` them onto an already-created
instance without recreating it. `add-service` refuses a fragment whose services don't resolve with the
instance's others (e.g. a mediator without `openhim`), and changes nothing. `remove-service` removes only
the containers of the fragment it removes, and doesn't start or stop anything else; the fragment's
volumes are kept, and it names them. Each mediator is its own fragment file; more than one can be
attached to the same OpenHIM instance at once. A service's default env vars live in a sibling
`<service>.env.defaults` file next to its `docker/services/<service>.yaml`; `create` and
`add-service` both pick these up automatically for whichever services you select, so attaching a
service via either command writes its required settings into the instance's `env` file for you.
`.env.defaults` is the only place those defaults are defined: the fragment requires the variables it
uses (`${VAR?}`), so one missing from `env` stops the command with an error naming it, rather than
falling back to a second default or a blank. `openmrs-docker <name> sync` adds any that are
missing. Its
`# container-env:` line, if any, says which of those variables go into the container itself (see
"`env` file reference").

OpenHIM's clients authenticate with Basic auth or custom tokens; its JWT authentication is off,
since nothing uses it and it would otherwise accept a token signed with a shared secret for any client.

Inside the instance's Docker network, OpenHIM and its mediators talk plain HTTP, including
openhim-core's admin API; TLS for access from outside is the reverse proxy's job. `openhim.yaml`
publishes only what's used from outside, and its comments say why each one is:

| Variable | Default | Published for |
|---|---|---|
| `OPENHIM_CONSOLE_HOST_PORT` | `9000` | the admin console |
| `OPENHIM_ADMIN_API_HOST_PORT` | `8081` | the admin API, which the console (running in the admin's browser) calls directly |
| `OPENHIM_ROUTER_HTTP_HOST_PORT` | `5001` | the router, for external systems calling a channel. A proxy in front should forward only those channels' paths: some channels are public |

Behind a proxy, tell the console where the browser finds the admin API, and set the console's own
address for links openhim-core generates. The defaults are for a browser on the same machine:

| Variable | Default |
|---|---|
| `OPENHIM_CONSOLE_API_PROTOCOL`, `OPENHIM_CONSOLE_API_HOST`, `OPENHIM_CONSOLE_API_PORT`, `OPENHIM_CONSOLE_API_PATH` | `http`, `localhost`, `OPENHIM_ADMIN_API_HOST_PORT`, empty |
| `OPENHIM_CONSOLE_URL` | `http://localhost:<OPENHIM_CONSOLE_HOST_PORT>` |

OpenHIM's MongoDB database is named `openhim` (it was `openhim-development` before TASKS-596). An
instance created before starts on an empty database: `openhim-setup` sets the admin password
again and each mediator registers and provisions its channels and clients on its next start, but
the transaction log, audit events, metrics and anything changed by hand in the console aren't
carried over. The old database stays in the `mongo-data` volume, to copy with `mongodump` /
`mongorestore --nsFrom 'openhim-development.*' --nsTo 'openhim.*'` or drop.

For example, with the proxy serving the console at `https://openhim.example.org` and forwarding
`/api` there to the admin API: `OPENHIM_CONSOLE_API_PROTOCOL=https`,
`OPENHIM_CONSOLE_API_HOST=openhim.example.org`, `OPENHIM_CONSOLE_API_PORT=443`,
`OPENHIM_CONSOLE_API_PATH=/api`, `OPENHIM_CONSOLE_URL=https://openhim.example.org`.

The following example will create an instance with OpenHIM and its mediators installed,
configured for Lesotho:

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
export OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci
export SEED_IMAGE_NAME="partnersinhealth/lesotho-emr-seed-lesotho"
export OPENHIM_PASSWORD=<pick-a-password>
export ADVAPACS_MEDIATOR_INBOUND_SECRET=<pick-a-secret>
export ADVAPACS_MEDIATOR_OPENHIM_INBOUND_CLIENT_PASSWORD=<pick-a-password>
export ADVAPACS_CLIENT_ID=<advapacs-client-id>
export ADVAPACS_CLIENT_SECRET=<advapacs-client-secret>
export OPENMRS_USERNAME=<username-for-mediator-access-to-openmrs>
export OPENMRS_PASSWORD=<password-for-mediator-access-to-openmrs>
export ADVAPACS_PATIENT_IDENTIFIER_SYSTEM="http://www.pih.org/identifiers/lesotho/emr-id"
export SERVICES=openmrs-db,openmrs,openhim,openhim-advapacs-mediator
openmrs-docker create <name>
openmrs-docker <name> initialize
openmrs-docker <name> start
```

## Adding petl and its SQL Server target

Two more fragments under `docker/services/` are attached the same way as OpenHIM and its mediators
— via `SERVICES=` at `create` time, or `add-service` on an existing instance:

- **`petl`** runs the [petl](https://github.com/PIH/petl) ETL pipeline against this instance's
  `openmrs-db`. It's a *profiled* fragment, so `start` deliberately doesn't bring it up; it's a job,
  not a long-running service. Invoke it with `run-service`. It needs `PETL_IMAGE_NAME` set — if it
  isn't, `run-service petl` fails on a placeholder image name rather than a real one.
- **`petl-sqlserver`** is the SQL Server database petl writes to — the stock
  `mcr.microsoft.com/mssql/server` image directly, no custom build. A companion one-shot
  `petl-sqlserver-init` service creates the `PETL_SQLSERVER_DATABASE` database (default
  `openmrs_reporting`) once `petl-sqlserver`'s healthcheck confirms SQL Server itself is up, then exits.

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
export PETL_IMAGE_NAME=partnersinhealth/petl
export PETL_SQLSERVER_PASSWORD=<pick-a-password>
export SERVICES=openmrs-db,openmrs,petl,petl-sqlserver
openmrs-docker create <name>
openmrs-docker <name> start
openmrs-docker <name> run-service petl
```

Note that `PETL_SQLSERVER_PASSWORD` has a default committed to this repo, which exists only so the
fragment works out of the box for local development — override it for anything else.

## Testing this project

The `test/` directory holds a [bats](https://github.com/bats-core/bats-core) test suite for this
project's own scripts, run by `.github/workflows/test.yml` on every push and pull request that touches
`bin/`, `utils/`, `docker/` or `test/`. Run it locally with:

```bash
test/run                 # everything
test/run static          # shellcheck, and every Compose fragment/overlay validates (seconds)
test/run args            # argument validation and safety checks (seconds)
test/run integration     # backup -> restore -> verify round trips against real containers (minutes)
test/run integration/dump.bats -f '7z'   # one file, filtered by test name
```

It needs Docker, git, jq, curl and perl: `test/run` fetches pinned versions of bats and GNU parallel
into `test/.deps/` on first use, and falls back to the `koalaman/shellcheck-alpine` image if
`shellcheck` isn't installed. Tests run in parallel, `TEST_JOBS` at a time (default: the number of
CPUs, up to 8; `TEST_JOBS=1` runs them one at a time); with 8 jobs the whole suite takes about a
minute and a half. Tests create everything under a unique name prefix (throwaway `OPENMRS_DOCKER_HOME`, random host ports, a
placeholder OpenMRS image -- `initialize` only ever starts the database) and remove it all afterwards,
so they don't touch existing instances.
