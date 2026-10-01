# Running an instance

An instance is a directory under `$OPENMRS_DOCKER_HOME` (default `~/openmrs`) holding its `env` file
and a copy of the Compose fragment of each of its services, run as one Docker Compose project named
after the instance. Run `openmrs-docker` with no arguments for every command and option.

## Creating an instance

Each distribution has its own published image and, if it uses one, its own PIH config profiles; its
README lists them. `OPENMRS_IMAGE_NAME` is required for an instance with the `openmrs` service (one of
the defaults). `OPENMRS_PIH_CONFIG` is optional, since not every distro uses one, but a distro that
needs it fails at startup without it. The instance name is also its Compose project name, so it must
be lowercase letters, digits, `-` and `_`, starting with a letter or digit:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci \
OPENMRS_HTTP_PORT=9090 \
openmrs-docker create <name>
```

`create` writes every setting to the instance's `env`, taking a value set in your shell over its
default ([The env file](env.md)). So a settings file you source first works too, as long as it
`export`s each variable (plain `KEY=value` lines only set shell variables, which `openmrs-docker`
never sees):

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

To start from another instance's `env` instead, wrap the `source` in `set -a`/`set +a`: those files
use plain `KEY='value'` lines, since they're also Docker Compose `--env-file`s.

```bash
set -a; source ~/openmrs/other-instance/env; set +a
openmrs-docker create <name>
```

`SERVICES=<comma-separated>` (default `openmrs-db,openmrs`) chooses the services
([Optional services](services.md)). To keep instances apart from `openmrs-sdk` servers, which also
live in `~/openmrs` by default, set `OPENMRS_DOCKER_HOME`.

Before the first start, [`initialize`](restore.md) can fill the instance's volumes from a seed image
or a backup, which is much faster than OpenMRS building them up itself.

## Starting, stopping and logs

```bash
openmrs-docker <name> start
openmrs-docker <name> wait      # until OpenMRS has started (its /health/started endpoint)
```

When `wait` prints **OpenMRS is ready**, go to `http://localhost:8080/openmrs` (or the instance's
`OPENMRS_HTTP_PORT`).

```bash
openmrs-docker <name> logs [service]   # follow the logs, of every service by default
openmrs-docker <name> status           # the containers, and the command holding the lock, if any
openmrs-docker <name> stop             # removes the containers; the data stays in the volumes
openmrs-docker <name> destroy          # removes the containers, the volumes and the instance directory
```

`restart` restarts the containers in place, so it doesn't pick up changes to `env`; `start` does.

## Updating

```bash
openmrs-docker <name> update    # pulls the latest images, and recreates the containers that changed
```

An instance keeps its own copy of each service's fragment, so a newer version of this tool doesn't
change it by itself. `start` and `update` say when a fragment differs from the tool's (without
changing anything), and `sync` brings them up to date:

```bash
openmrs-docker <name> sync
openmrs-docker <name> update
```

`sync` also adds to `env`, with its default, any variable the refreshed fragments require that `env`
lacks, and prints the names it added. It never changes a variable already in `env`, and doesn't put
back an optional one you deleted (e.g. an `OPENMRS_DB_OPT_*` server option).

## Building a distro from source (developers)

Set `DISTRO_SOURCE_DIR` (at `create`, or later in `env`) to a checkout of the distro, then:

- `start --build` or `update --build` builds the distro (`mvn clean package`) and its image first;
  `build` does only that.
- `start --dev` or `update --dev` runs the image with what you last built mounted over its distro,
  and with Java debugging on `OPENMRS_DEBUG_PORT`.

## One command at a time

Every command that changes an instance (`initialize`, `start`, `stop`, `restart`, `update`, `pull`,
`build`, `sync`, `add-service`, `remove-service`, `reset-openmrs-db-accounts`, `destroy`) holds a lock
on it until it exits, and refuses to run while another command holds it, naming that command:

```
error: <name> is busy: initialize (pid 12345, started 2026-09-30 11:39:19) -- run this again once that finishes.
```

So on a puppet-managed host, the `pull && start` puppet runs on every apply fails, and changes
nothing, while an `initialize`, `reset-openmrs-db-accounts` or PETL run is in progress. With
`OPENMRS_DOCKER_LOCK_WAIT=<seconds>` set, a command waits up to that long for the lock instead, and
then fails naming the holder (puppet's deploys wait an hour). `run-service` holds the lock for a
service that declares it (`# run-service: holds-lock` in its `.env.defaults`; petl does, so a deploy
can't restart MySQL under a PETL run). It doesn't wait for, or need, OpenMRS: PETL also runs against
restored databases with no OpenMRS. For other services (the smoke tests) it refuses while the instance is busy but doesn't hold the
lock. `status`, `logs` and `wait` never wait for it. The lock is released however its holder exits,
so there's nothing to clean up after a crash. It uses `flock(1)` (util-linux, on every Linux host);
where `flock` isn't installed (e.g. macOS), commands run unlocked.

## Changing the database passwords

`OPENMRS_DB_PASSWORD` can't contain a backslash, and neither can `OPENMRS_DB_ROOT_PASSWORD` with a
MySQL image: the MySQL images' first setup and openmrs-core's first install store it wrongly, so
`openmrs-db` refuses one before setting up an empty data directory (MariaDB's images handle it in
the root password).

Changing either password in `env` changes nothing by itself: MySQL takes them only when it sets up an
empty data directory, and OpenMRS (core 2.6+) keeps the connection settings its runtime properties
file got on its first start. After editing `env`, run:

```bash
openmrs-docker <name> reset-openmrs-db-accounts
```

It stops the instance, sets the MySQL accounts to the passwords in `env` (with
`reset-mysql-accounts`), sets `connection.username` and `connection.password` in
`openmrs-runtime.properties` in `openmrs-data` (keeping the previous file as
`openmrs-runtime.properties.bak`, which still holds the old password), and starts it again. Until it
runs, the database reports unhealthy: its healthcheck already uses the new password.

## Updating this tool, and pinning it

The tool is a git clone, so `git pull` in it updates it, and `git checkout <commit/branch/tag>` pins
it. Then `sync` each instance to take up changed fragments (above).

## Troubleshooting on Windows

**"Permission denied" connecting to Docker:** close the Ubuntu terminal and reopen it from the Start
Menu. The docker group the setup script added you to only applies to new sessions.

**OpenMRS runs very slowly or runs out of memory:** WSL2 limits its memory by default. Create or edit
`C:\Users\<YourName>\.wslconfig` with the following, then restart WSL (`wsl --shutdown` in
PowerShell):

```
[wsl2]
memory=8GB
```
