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
with the name of the instance you want to create (this can be any name you like):

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci \
DISTRO_SOURCE_DIR="<path_to_lesotho_emr_src>" \
openmrs-docker create <name> --build
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
`source` in `set -a`/`set +a` — those files use plain `KEY=value` (no `export`), since they also
have to work as a Docker Compose `--env-file`:

```bash
set -a; source ~/openmrs/other-instance/env; set +a
openmrs-docker create <name>
```

Creating a new instance will create a new directory under `$OPENMRS_DOCKER_HOME` on your machine (defaults to `$HOME/openmrs`)
containing the environment configuration and a pre-initialized Docker image.  If you wish to keep your docker instance directories
separate from your openmrs-sdk instance directories, you can set the `$OPENMRS_DOCKER_HOME` environment variable to a different location.

## `env` file reference

| Variable | Required? | Purpose |
|---|---|---|
| `OPENMRS_IMAGE_NAME` | Required | OpenMRS image, no tag |
| `OPENMRS_PIH_CONFIG` | Optional | PIH config profile for this instance — leave unset if the distro doesn't use one; OpenMRS fails at startup if it does and this is missing |
| `DISTRO_SOURCE_DIR` | Required for `build`/`--dev`/`--build` only | Path to the distro repo checkout |
| `SEED_IMAGE_NAME` | Required for `initialize` unless a `RESTORE_MYSQL_*`/`RESTORE_OPENMRS_DATA_PATH` source is given for every volume (see "Initializing a server" below) | Full seed image name (no tag) |
| `SERVICE_NAME` | Optional (defaults to the instance name) | Docker Compose project name |
| `OPENMRS_IMAGE_TAG`, `SEED_IMAGE_TAG` | Optional (`latest`) | Image tags |
| `OPENMRS_HTTP_PORT`, `OPENMRS_DB_PORT`, `OPENMRS_DEBUG_PORT` | Optional | Port overrides — set differently per instance to run more than one at once |
| `TZ` | Optional (`UTC`) | Container timezone |
| `OPENMRS_DB_IMAGE_NAME` (`mysql`), `OPENMRS_DB_IMAGE_TAG` (`5.6`), `OPENMRS_DB_USER`, `OPENMRS_DB_PASSWORD`, `OPENMRS_DB_ROOT_PASSWORD`, `OPENMRS_ACTIVITYLOG_ENABLED`, `OPENMRS_DB_MEMORY_LIMIT`, `OPENMRS_MEMORY_LIMIT`, `OPENMRS_JAVA_MEMORY_OPTS`, `OPENMRS_DB_MAX_ALLOWED_PACKET`, `OPENMRS_DB_INNODB_BUFFER_POOL_SIZE` | Optional | Tuning knobs |
| `SERVICES` | Optional (`openmrs-db,openmrs`) | Comma-separated canonical fragments to copy into the instance at `create` time — see `docker/services/` |

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
| `RESTORE_MYSQL_DUMP_PATH` | `mysql/db-data` | a plain `.sql`/`.sql.gz` dump, handed to MySQL's own first-boot import |
| `RESTORE_MYSQL_DATA_PATH` | `mysql/db-data` | a ready MySQL data directory, copied straight into the volume before MySQL ever starts (far faster for a large database) |
| `RESTORE_OPENMRS_DATA_PATH` | `openmrs-data` | an already-extracted directory, copied straight into the volume |

`mysql/db-data` requires exactly one source: `RESTORE_MYSQL_DUMP_PATH`, `RESTORE_MYSQL_DATA_PATH`,
or `SEED_IMAGE_NAME`. `openmrs-data` is optional -- if neither `RESTORE_OPENMRS_DATA_PATH` nor
`SEED_IMAGE_NAME` is set, that volume is simply left for OpenMRS's own first-boot
module-initializer run to build up from scratch, same as a totally fresh install (e.g. when
restoring a real database backup with no matching `openmrs-data` backup to go with it).

```bash
# restore the database from a logical dump, but still seed openmrs-data from the nightly image
RESTORE_MYSQL_DUMP_PATH=/path/to/backup.sql.gz SEED_IMAGE_NAME=... openmrs-docker <name> initialize

# restore both volumes from real backups, no seed image involved at all
RESTORE_MYSQL_DATA_PATH=/path/to/datadir RESTORE_OPENMRS_DATA_PATH=/path/to/data-dir openmrs-docker <name> initialize

# restore only the database from a backup; let openmrs-data build up fresh
RESTORE_MYSQL_DATA_PATH=/path/to/datadir openmrs-docker <name> initialize
```

None of the above handle an archive or a raw (not yet copied-back) percona/xtrabackup backup --
`RESTORE_MYSQL_DUMP_PATH`/`RESTORE_MYSQL_DATA_PATH`/`RESTORE_OPENMRS_DATA_PATH` are always plain,
ready-to-use paths. Preparing one from an archive or a physical backup is a separate step, using
the standalone scripts in `utils/` (see below):

Only `bin/` is on `PATH` (see "Install" above) -- run these from `$DISTRO_TOOLS_HOME/utils/...`,
or `cd` there first:

```bash
# an archive (optionally password-protected) wrapping a plain dump
DUMP=$(ARCHIVE_PASSWORD=<password> $DISTRO_TOOLS_HOME/utils/extract-archive.sh --path=/path/to/backup.sql.gz.7z)
RESTORE_MYSQL_DUMP_PATH="$DUMP" openmrs-docker <name> initialize

# a percona/xtrabackup backup: extract the archive, then convert it into a ready datadir
BACKUP_DIR=$($DISTRO_TOOLS_HOME/utils/extract-archive.sh --path=/path/to/backup.7z --output-dir=./backup)
DATADIR=$($DISTRO_TOOLS_HOME/utils/convert-percona-backup.sh --backup-dir="$BACKUP_DIR" --output-dir=./datadir)
RESTORE_MYSQL_DATA_PATH="$DATADIR" openmrs-docker <name> initialize
```

**A caveat specific to `RESTORE_MYSQL_DATA_PATH`:** a physical backup is a copy of the source
server's entire data directory, *including its `mysql` system tables* -- so the restored database's
real credentials are the source server's, not the ones this instance was created with. If
`OPENMRS_DB_USER`, `OPENMRS_DB_PASSWORD` and `OPENMRS_DB_ROOT_PASSWORD` don't match what the source
server actually used, the database will come up fine but the post-restore health check can never
authenticate, and `initialize` reports a timeout even though the restore itself succeeded. Set those
variables to the source server's credentials before running `create`. For the same reason,
`OPENMRS_DB_IMAGE_TAG` should match the MySQL version the backup was taken from. `RESTORE_MYSQL_DUMP_PATH`
is unaffected -- a logical dump doesn't carry the source's user accounts.

### Utilities (`utils/`)

Standalone, general-purpose scripts in this tool's own `utils/` directory (not part of the
`openmrs-docker` CLI, and usable entirely on their own -- e.g. against a production server that was
never created via `openmrs-docker` at all). Named arguments for values; secrets (passwords) are
environment variables instead, so they never show up in `ps` output. Run any script with no
arguments for its exact usage.

- **`extract-archive.sh --path=<path> [--output-dir=<dir>]`** -- extracts a `.7z`/`.zip`/`.tar.gz`/
  `.tgz`/`.tar` archive (optional `ARCHIVE_PASSWORD` env var, `.7z`/`.zip` only) and prints the path
  to its single top-level entry; prints `<path>` unchanged for anything else.
- **`convert-percona-backup.sh --backup-dir=<dir> --output-dir=<dir>`** -- converts an extracted,
  already-prepared (`--apply-log`'d) percona/xtrabackup backup directory into a ready-to-use MySQL
  data directory (`--copy-back`), suitable for `initialize`'s `RESTORE_MYSQL_DATA_PATH`.
- **`backup-mysqldump.sh --container=<name> --output=<path> [--database=openmrs] [--user=root]`**
  -- dumps a running MySQL container's database (`MYSQL_PASSWORD` env var), including routines and
  triggers, as a faithful, unmodified copy. `--output` ending in `.gz` produces a plain
  gzip-compressed SQL file; ending in `.7z` produces a password-protected archive instead
  (`ARCHIVE_PASSWORD` env var, required), matching PIH's existing backup convention -- either way
  the dump is streamed straight into the compressor, never written to disk unencrypted.
- **`strip-mysqldump-definers.sh --path=<dump.sql|dump.sql.gz> --output=<path>`** -- an optional
  step for a dump produced above: strips `DEFINER=`user`@`host`` clauses from routines/triggers/
  views into a new copy (the original is untouched), so a definer account that doesn't exist on
  the restore target doesn't cause a restored routine/trigger to fail at execution time. Only
  needed if/when you actually hit that problem.
- **`backup-percona.sh --container=<name> --volume=<db data volume> --output=<dir>`** -- takes a
  prepared physical backup of a running MySQL container's data volume (`MYSQL_ROOT_PASSWORD` env
  var), ready for `convert-percona-backup.sh`.
- **`clear-configuration-checksums.sh --volume=<openmrs-data volume>`** -- removes
  openmrs-module-initializer's cached `configuration_checksums` from a volume (refuses if a running
  container currently has it mounted), so the next start reprocesses all configuration from
  scratch rather than trusting checksums that may no longer reflect reality -- e.g. after loading a
  different database while keeping an existing `openmrs-data`.
- **`wait-for-healthy.sh --container=<name> [--timeout=<seconds>] [--fail-on-unhealthy=true|false]`**
  -- polls until a container reports healthy; fails fast on exited/dead/restarting, or times out.

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
instance without recreating it. Each mediator is its own fragment file; more than one can be
attached to the same OpenHIM instance at once. A service's default env vars live in a sibling
`<service>.env.defaults` file next to its `docker/services/<service>.yaml`; `create` and
`add-service` both pick these up automatically for whichever services you select, so attaching a
service via either command writes its required settings into the instance's `env` file for you.

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
