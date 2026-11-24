# dhis2

DHIS2, in the stock Tomcat image (`tomcat:<tag>`) for its Java, serving at `/dhis`. It requires
`dhis2-db`. The DHIS2 home (`dhis.conf`, `files/`, `apps/`) is in the `dhis2-data` volume, and the
release WARs are in `dhis2-wars`. Settings are in the instance's `dhis2.env`; defaults are in
[`env.defaults`](env.defaults).

| Variable | Default | |
|---|---|---|
| `DHIS2_VERSION` | none: must be set | a version in [`scripts/versions`](scripts/versions), e.g. `2.43.2.1` |
| `DHIS2_TOMCAT_TAG` | `10.1-jdk17-temurin-noble` | the Tomcat image's tag: the one `scripts/versions` gives for `DHIS2_VERSION`. The default is right for 2.42 and 2.43; an instance on an earlier version sets it too |
| `DHIS2_HTTP_PORT` | `8080` | the port published on the host; set it differently to run more than one instance at once |
| `DHIS2_BASE_URL` | `http://localhost:<DHIS2_HTTP_PORT>/dhis` | `server.base.url`: the address users reach DHIS2 at |
| `DHIS2_ENCRYPTION_PASSWORD` | empty (none) | `encryption.password`. An instance restored from another must have that one's, or DHIS2 can't read what it encrypted |
| `DHIS2_MEMORY_LIMIT`, `DHIS2_JAVA_OPTS` | `4g`, `-Xms1g -Xmx3g` | the container's memory limit, and Tomcat's Java options |
| `DHIS2_TEST_COPY` | `false` | `true` only on a copy of production: each `pihx` start or update turns off its outbound email and sending jobs (not a reboot: [below](#a-copy-of-production)) |
| `DHIS2_UPGRADE_STEP_TIMEOUT` | `7200` | seconds each version has to come up during an [upgrade](#upgrading) |
| `DHIS2_CONF_<key>` | none | any other `dhis.conf` setting ([below](#dhisconf)) |

The database's name and user are `dhis2-db`'s settings: `dhis2` doesn't redefine them. `DHIS2_DB_PASSWORD`,
which has no default, is written by `create` into `dhis2.env` (the first service by name that refers to
it), so the `dhis2` Tomcat container has it in its environment through that file, as well as
`dhis2-setup`, which writes it into `dhis.conf`. DHIS2 reads it from `dhis.conf` either way; anyone who
can `docker inspect` the container could read the volume too. `TZ` comes from `instance.env`.

**Nothing in this repo changes the version an instance runs on its own.** `DHIS2_VERSION` has no default, and
DHIS2's database migrations can't be undone, so the instance's own env (Puppet's `site.pp`) names the
version, and changing it is the only way to upgrade. `pihx <name> dhis2 upgrade`, run by an operator,
changes it one version at a time ([below](#upgrading)).

## Versions

[`scripts/versions`](scripts/versions) lists the versions this service runs, oldest first, one per line:
`<version> <tomcat tag> <WAR URL> <WAR SHA-256>`. Each is the final patch of its minor version and
an upgrade step, since DHIS2's migrations can't skip a minor version. The tag pins the Tomcat
and JDK the version needs, and the Ubuntu release, so `pull` brings Tomcat and Java patches but
never a new OS release: Tomcat 9 with JDK 8 up to 2.37, JDK 11 for 2.38 to 2.40 and JDK 17 for 2.41;
Tomcat 10.1 with JDK 17 for 2.42 and 2.43, which are Jakarta EE and never start in Tomcat 9.

To add a version: take its WAR URL and SHA-256 from
[DHIS2's release metadata](https://releases.dhis2.org/v1/versions/stable.json) (`.versions[] |
select(.name=="2.43") | .patchVersions[]`), and its JDK from the same file. Add the line in its place
in the list, oldest first, with the Tomcat tag for that JDK and servlet API (`<tomcat>-jdk<N>-temurin-<ubuntu
release>`: Tomcat 10.1 for a WAR with `jakarta.servlet-api` in `WEB-INF/lib`, 9 for one with
`javax`). The tag must exist on Docker Hub.

## Starting

Before every start, `dhis2-setup` runs [`scripts/setup.sh`](scripts/setup.sh) in the same Tomcat image,
and `dhis2` starts only if it succeeds. In order, it:

1. looks up `DHIS2_VERSION` in `scripts/versions`;
2. checks that `DHIS2_TOMCAT_TAG` is that version's tag;
3. refuses a downgrade or a skipped version: the DHIS2 home's `.dhis2-version` records the last
   version set up, and an earlier `DHIS2_VERSION` fails the start (e.g. a Puppet apply that puts an
   old version back after an upgrade), as does one more than one line later in the list (step with
   `pihx <name> dhis2 upgrade`). With no `.dhis2-version` (a new instance, or one restored from a
   home that never ran this service) nothing is checked;
4. makes sure `dhis2-wars` holds the version's WAR, `dhis2-<version>.war`. A WAR already there is
   kept if its SHA-256 matches; otherwise it's downloaded with `curl` and verified. **The host needs
   internet access at a start that needs a new WAR.**
5. writes `dhis.conf` (mode 600) into the DHIS2 home from the settings above, every time;
6. writes `.dhis2-version`.

`dhis2-test-copy` runs too, once `dhis2-db` is healthy, and `dhis2` starts only if it succeeds: on a
copy of production it turns off outbound email and the jobs that send data out
([below](#a-copy-of-production)); on any other instance it prints `dhis2-test-copy: not a test copy,
nothing changed`.

Then `dhis2` runs Tomcat with our [`scripts/server.xml`](scripts/server.xml), which deploys the
version's WAR at `/dhis`. It has one HTTP connector with the query characters DHIS2's API uses
allowed, no AJP and no shutdown port. Its `RemoteIpValve` takes the scheme from `X-Forwarded-Proto`,
so behind a TLS-ending proxy DHIS2's redirects are https. The healthcheck
([`scripts/healthcheck.sh`](scripts/healthcheck.sh)) passes once `/dhis/` answers. Its first two hours
(`start_period`) don't count against it, for an upgrade's migrations; a migration that runs longer
leaves it `unhealthy` while it carries on, which `pihx <name> dhis2 upgrade` still treats as
starting ([When a step fails](../../docs/dhis2.md#when-a-step-fails)).

DHIS2 runs as root, the stock Tomcat image's user.

DHIS2 and Tomcat log only to the console, so to `docker logs` (`pihx <name> logs dhis2`), as the
other services do ([Starting, stopping and logs](../../docs/instances.md#starting-stopping-and-logs)).
DHIS2 would otherwise also write log files under `logs/` in its home, among them an audit log it
never deletes: the Java options in `compose.yaml` point log4j at the WAR's own console-only
configuration, which makes DHIS2 skip them, and [`scripts/logging.properties`](scripts/logging.properties)
replaces Tomcat's, which writes files in the container. The `logging.file.*` settings in `dhis.conf`
have no effect.

### When a start fails

`pihx <name> start` fails saying only that `dhis2-setup` didn't complete successfully: Compose stops
before pihx can show its log. **The reason is in `pihx <name> logs dhis2-setup`**, as one of these:

| Message | |
|---|---|
| `DHIS2_VERSION '<v>' isn't in services/dhis2/scripts/versions` | a version this repo doesn't list |
| `DHIS2 <v> runs on tomcat:<tag>; DHIS2_TOMCAT_TAG is <other>` | set `DHIS2_TOMCAT_TAG` as it says |
| `this instance last ran DHIS2 <old>; DHIS2_VERSION is <new>` | a downgrade: set `DHIS2_VERSION` back to `<old>` or later |
| `this instance last ran DHIS2 <old>; DHIS2_VERSION <new> skips versions` | `<new>` is more than one step past `<old>`: set `DHIS2_VERSION` back to `<old>` and step with `pihx <name> dhis2 upgrade` |
| `this instance last ran DHIS2 <old> (...), which isn't in services/dhis2/scripts/versions` | the version marker names a version this repo doesn't list, so setup can't tell whether `DHIS2_VERSION` is a downgrade: run it from tools that list `<old>` |
| `couldn't download <url>` | no internet access, or the release moved |
| `the download from <url> has SHA-256 ...` | the download isn't the release the list names: it's deleted, never used |

A failed `dhis2-test-copy` is in `pihx <name> logs dhis2-test-copy` in the same way.

## A copy of production

An instance that holds a copy of production (lsdata-test, for trainings) sets `DHIS2_TEST_COPY=true` in
its `dhis2.env`. Then, at each `pihx <name> start` or `update` (and a Puppet apply, which runs one),
before DHIS2 starts, `dhis2-test-copy` runs
[`scripts/test-copy.sql`](scripts/test-copy.sql) on the database (`psql` in `dhis2-db`'s image, in one
transaction) and prints `dhis2-test-copy: outbound email and sending jobs turned off`. It:

- deletes the email server's settings (`keyEmailHostName`, `keyEmailPort`, `keyEmailUsername`,
  `keyEmailPassword`, `keyEmailSender`, `keyEmailTls`), so DHIS2 sends no email;
- deletes the remote instance that data and metadata sync send to (`keyRemoteInstanceUrl`,
  `keyRemoteInstanceUsername`, `keyRemoteInstancePassword`);
- deletes the SMS gateways (the `keySmsSetting` setting up to 2.41, the datastore's
  `sms-config`/`config` from 2.42);
- turns off the scheduled jobs that send data out or message people: notifications, scheduled
  messages, data, metadata and program sync, SMS, push analysis, data exchange, monitoring and
  expiry alerts (the list, with the versions each exists in, is in `test-copy.sql`). Other jobs, such
  as analytics, are left alone.

It runs at each `pihx` start or update, so an admin who turns any of it back on during a training has
it turned off again at the next one. It changes rows that are there and skips tables that aren't (an empty
database, before DHIS2's first start), on every version from 2.30 to 2.43; a schema it doesn't
recognize fails the start rather than changing nothing: a table it changes that lacks the column it
works by (PX001: `jobconfiguration.enabled`; PX003: `systemsetting.name` or `keyjsonvalue.namespacekey`),
or a job type column it doesn't know (PX002). Errors show only their SQL state (PX001 to PX003 are its
own checks, in `test-copy.sql`), since a message could quote a row's values. A job DHIS2
itself creates during a start (a new version's built-in job, at an upgrade) is turned off at the next
one; with no email server or SMS gateway it has nothing to send through meanwhile. A value other
than `true` or `false` fails the start. Never set it on production.

**It runs only when pihx starts the instance, not whenever DHIS2 starts:**

- **After a host reboot or a Docker restart**, `restart: unless-stopped` brings DHIS2 back without
  `dhis2-test-copy` (or `dhis2-setup`); and `pihx <name> restart` (`docker compose restart`) restarts
  containers in place without waiting for the guard before DHIS2. Whatever an admin turned back on stays on. On a test copy, after a reboot run
  `pihx <name> stop && pihx <name> start`.
- **A start or update that doesn't recreate `dhis2`** (nothing about it changed: a Puppet apply, a
  second `pihx <name> start`) still runs the guard, but under a running DHIS2. DHIS2 caches its
  settings, so it may keep the old email or SMS settings until it restarts, and before 2.41 its
  scheduler can write `enabled = true` back to a job it holds. Stop and start it to be sure.

## dhis.conf

`dhis.conf` is written on every start, so edits to it are lost: change the instance's settings
instead. It has the database connection (`dhis2-db`, with `DHIS2_DB_NAME`, `DHIS2_DB_USER` and `DHIS2_DB_PASSWORD`),
`connection.schema = update`, `server.base.url` and, if set, `encryption.password`. Each
`DHIS2_CONF_<key>` adds a line, `_` in `<key>` becoming `.` and `__` becoming `_`: for example,
`DHIS2_CONF_connection_pool_max__size=40` gives `connection.pool.max_size = 40`. Such a line comes
after the ones above, so it's the one DHIS2 reads. At `create`, the `DHIS2_CONF_*` in your shell go
into `dhis2.env` (the manifest's `capture-env`). Values are written as a Java properties file reads
them, with a backslash doubled.

## Upgrading

`pihx <name> dhis2 upgrade [--to=<version>] [--with-fix=<version>/<file>]...` steps the instance to the
next version in the list (or each one up to `--to`): it runs the chosen
[known fixes](known-fixes), sets `DHIS2_VERSION` and `DHIS2_TOMCAT_TAG` in `dhis2.env`, starts the
instance and waits up to `DHIS2_UPGRADE_STEP_TIMEOUT` seconds (default 7200) for DHIS2 to come up. A
version that didn't come up is retried by the next run, never skipped, and a DHIS2 still starting
(perhaps migrating) is never stopped. Its output never includes log text, which could quote data: a
failed migration is shown as its name and SQL state
([`scripts/flyway-errors.sh`](scripts/flyway-errors.sh)). The procedure, before and after, the known
fixes and refreshing a test copy are in
[DHIS2: upgrading, patching and test copies](../../docs/dhis2.md).

## Resetting a password

`pihx <name> dhis2 reset-password [<username>]` (default `admin`) sets a user's password in the
database ([`commands/reset-password`](commands/reset-password)): for an instance restored from another
server, whose logins nobody here has. It asks for the password twice without echoing it, or reads one
line from stdin (`printf '%s\n' "$pw" | pihx <name> dhis2 reset-password <username>`). It also enables
the account and turns off LDAP/external login and two-factor for it.

**It stops DHIS2 and leaves it stopped**: start it with `pihx <name> start`. A running DHIS2 keeps the
users it has loaded and writes one back, old password included, at that user's next login, so a change
made under it doesn't last. A DHIS2 still starting (perhaps migrating) is refused instead, and
`dhis2-db` is started if it isn't running. The password is hashed with bcrypt by Postgres's
`pgcrypto`, installed only inside a transaction that's rolled back, so the database gains no
extension; neither the password nor the hash is on a command line or printed.

## Backup, restore and summary

The `backups` service runs [`scripts/backup.sh`](scripts/backup.sh) ([Backups](../../docs/backups.md)):
the `dhis2-data` volume into `dhis2.7z`, holding one directory, `dhis2/`, with the instance running.
It holds everything in the volume but three: `dhis.conf` (`dhis2-setup` writes it on every start, and
it holds the database password), `.dhis.conf.new` (left by a setup that failed before renaming it,
with the password too) and `logs/` (DHIS2 doesn't write it here, but a restored legacy home can have one). So: `files/`, `apps/`, the version marker
`.dhis2-version`, and anything else DHIS2 keeps in its home. The WARs in `dhis2-wars` are fetched
again, so they aren't backed up.

`initialize --from` restores `dhis2.7z`, `dhis2.tar.gz`, `dhis2.tgz`, `dhis2.tar` or `dhis2.zip` into
`dhis2-data` ([`restore/archive.yaml`](restore/archive.yaml)). A single top-level directory is
unwrapped, so an archive of a legacy DHIS2 home (`files/` and `apps/` at the top, as RIMU keeps it)
restores as it is, and so does the backup's `dhis2/`. A legacy `dhis.conf` in the archive is
replaced by `dhis2-setup`'s on the first start; the version marker, if the archive has none, is
written then, so `DHIS2_VERSION` must be exactly the source's version ([Refreshing a test
copy](../../docs/dhis2.md#refreshing-a-test-copy-from-production)). Set `DHIS2_ENCRYPTION_PASSWORD` to the source's if it had one.

`pihx <name> summary` prints `[dhis2]`: `files <n>` and `apps <n>`, the number of files under
`files/` and `apps/`, and `version <marker>` (`none` before the first start).
