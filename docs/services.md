# Services

An instance is a set of services, and a service is a directory under `services/` in this repo.
Everything that exists only because of one service lives in its directory, so removing a service
means removing it.

| Service | What it is | Docs |
|---|---|---|
| `openmrs-db` | The OpenMRS database (MySQL or MariaDB), and the setup that keeps its declared accounts in place | [README](../services/openmrs-db/README.md) |
| `openmrs` | The OpenMRS application (requires `openmrs-db`) | [README](../services/openmrs/README.md) |
| `openhim` | OpenHIM: core, console and MongoDB. Also the AdvaPACS mediator, `openhim-advapacs-mediator` | [README](../services/openhim/README.md) |
| `advapacs-gateway` | AdvaPACS's on-premises gateway for DICOM from local modalities | [README](../services/advapacs-gateway/README.md) |
| `modality-simulator` | A fake CR, US and CT modality, for testing the gateway | [README](../services/modality-simulator/README.md) |
| `biometrics` | The pih-biometrics fingerprint server | [README](../services/biometrics/README.md) |
| `sqlserver` | Microsoft SQL Server, and the setup for its settings, databases and logins | [README](../services/sqlserver/README.md) |
| `petl` | The PETL ETL job, run against `openmrs-db` and writing to SQL Server | [README](../services/petl/README.md) |
| `openmrs-smoke-tests` | The PIH EMR smoke tests, run against the instance's OpenMRS | [CI workflows](ci-workflows.md#running-smoke-tests-locally) |

## Adding and removing services

An instance's services are the `<service>.env` files in its directory ([An instance's
files](env.md)). Choose them at `create`, or add and remove them later:

```bash
pihx <name> create --services=openmrs-db,openmrs,petl,sqlserver
pihx <name> add-service <svc>
pihx <name> remove-service <svc>
```

(`openmrs-docker create <name>` takes `SERVICES=<comma-separated>` instead, default
`openmrs-db,openmrs`.) `add-service` writes `<svc>.env` from the values in your environment that
the service knows, and refuses a service whose `requires` the instance lacks (e.g. a mediator
without `openhim`), changing nothing. `remove-service` removes that service's containers, keeps its
volumes (naming them) and deletes its env file. Deleting the file by hand and running
`pihx <name> update` does the same, since the files present are the instance's services.

A job (PETL) isn't brought up by `start`: run it with `pihx <name> run-service [--pull] <svc>
[command...]` (`--pull` pulls its image first; a plain `pull` skips it).

## Writing a service

### The directory

```
services/<svc>/
  service.yaml             the manifest (required)
  compose.yaml             its containers (required)
  env.defaults             its defaults, literal KEY=value lines (required)
  with-<other>.yaml        what it adds to another service's containers, when the instance has both
  restore/                 overlays `initialize` adds, and the optional prepare and finish hooks
  start/                   its start-env scripts, if any (by convention)
  summary.sh               what `pihx <instance> summary` prints for it
  commands/<name>          `pihx <instance> <svc> <name>`
  scripts/                 scripts its containers mount
  README.md                its docs
```

The name is lowercase letters, digits, `-` and `_`, starting with a letter or digit, and can't be a
`pihx` command (`start`, `config`, ...) or `instance`. Only `service.yaml`, `compose.yaml` and
`env.defaults` are required; the rest is found by its presence. `pihx/tests/test_service_tree.py`
and `test/static/services.bats` check every service in the tree against the conventions below.

### The manifest

`service.yaml` has these fields and no others; an unknown key is an error naming it.

| Field | |
|---|---|
| `description` | Required: one line, what the service is |
| `requires` | Services that must also be in the instance (e.g. `[openmrs-db]`); `create` and `add-service` refuse without them, and they start first |
| `setup` | Containers of its `compose.yaml` that are one-shot setup, e.g. `[openmrs-db-accounts]`. `start` and `update` wait for them and fail, naming the one that didn't succeed; a job's run runs each as a one-off first |
| `start-env` | Scripts (paths in the service directory) that `start` and `update` run, in pihx's container, before Compose's `up`. Each prints `KEY=value` lines, values for that `up` only, never written anywhere; a script that fails or prints anything else gives nothing, with a warning. So the compose file's default for such a value must be the safe one. `openmrs`'s `start/create-tables` decides whether OpenMRS creates its tables |
| `capture-env` | Name prefixes (e.g. `[OMRS_EXTRA_]`). At `create` and `add-service`, a variable in your environment with such a prefix goes into the service's `.env` even though no default or compose file names it |
| `job` | `true` for a job: `start` doesn't bring it up and `run-service` runs it holding the instance lock |
| `backup` | `none`. Backups come with TASKS-597; until then a service says it has nothing to back up |
| `restore` | What `initialize` accepts, as a list of entries: `names` (the entries of the `--from` folder), `overlay` (a compose file under `restore/`) and optionally `after` (another, run after it, e.g. an account reset) |

```yaml
description: The OpenMRS database (MySQL or MariaDB), and the setup that makes sure its accounts exist
capture-env: [OPENMRS_DB_OPT_]
setup: [openmrs-db-accounts]
backup: none
restore:
  - names: [openmrs-db.sql, openmrs-db.sql.gz]
    overlay: restore/dump.yaml
```

### Variables: env.defaults and the instance's files

`env.defaults` holds the defaults every instance starts from, as plain `KEY=value` lines, with
comments on lines of their own. **Defaults are literals**: no `${OTHER}`, no `${VAR:-default}`. (A
reference would be resolved before the instance's own files are read, so an instance changing
`OTHER` wouldn't carry through. Derive a value in `compose.yaml` instead, as `${A:-${B}}`. A
single-quoted value may hold a `${...}` that is for the application, as petl's `PETL_MYSQL_OPTIONS`
does.) A value the instance must set has no default: `compose.yaml` requires it, as
`${NAME:?message saying what it is}`, so a missing one fails with that message.

Variables keep their service's prefix (`OPENMRS_DB_*`, `PETL_*`), because every file of an instance is
interpolated at once and a name two services define would collide; the tests check that none does. A
service defines the values it owns once: `openmrs` reads the database password `openmrs-db` owns,
from `openmrs-db.env`.

**The container convention.** A container gets its service's `env.defaults`, then its `<svc>.env`
(absent is fine), and whatever its `compose.yaml` passes under `environment:`. Nothing from another
service's file reaches it, nor `instance.env`, unless passed explicitly (`TZ: ${TZ}`). Every container
of a service declares exactly:

```yaml
    env_file:
      - path: ${PIHX_TOOLS}/services/<svc>/env.defaults
      - path: ${PIHX_INSTANCE_DIR}/<svc>.env
        required: false
```

`PIHX_TOOLS` is the instance's checkout, `PIHX_INSTANCE_DIR` its directory, and `SERVICE_NAME` its
name, which names containers: `container_name: ${SERVICE_NAME}-<container>`. A compose file has no
relative host paths (Compose would resolve them against the instance directory), so what it mounts
from the checkout is `${PIHX_TOOLS}/services/<svc>/scripts/<file>`.

### Contributing to another service: `with-<other>.yaml`

Where a service adds something to another's containers, it does so in
`services/<svc>/with-<other>.yaml`: a compose file applied only when the instance has both, after
every service's `compose.yaml` and before the instance's override files. It adds only to the other
service's containers, and the other service never names it. [petl's](../services/petl/with-openmrs-db.yaml)
adds PETL's MySQL account to `openmrs-db-accounts`' `environment:`, built from PETL's own values, so
changing PETL's account doesn't recreate the database container.

### Restore

`pihx <instance> initialize --from <folder>` gives each service the entry of the folder its manifest's
`restore` names. For each, the service's overlay (a compose file in `restore/`, added to the
instance's files for that one run) does the work in containers, given these variables, `<SVC>` being
the service's name in capitals with `-` as `_`:

| Variable | |
|---|---|
| `<SVC>_RESTORE_PATH` | the entry's path on the host |
| `<SVC>_RESTORE_NAME` | the entry's name, e.g. `openmrs-db.sql.gz` |
| `<SVC>_RESTORE_ARCHIVE` | for an archive, the `archive.<ext>` name to mount it as |

Entry names start with the service's name. Overlays mount the entry read-only (with long-syntax bind
mounts, so a missing source fails rather than becoming an empty directory) and may declare staging
volumes of their own, which are removed afterwards. Two optional hooks, executable files, are found by
their presence:

- `restore/prepare` runs first, before any volume exists, when the service has an entry. It prints
  `KEY=value` lines: values for that restore only (`openmrs`'s finds the owner of the restored
  files).
- `restore/finish` runs once the restore has worked (no service has one today). If anything fails, `initialize` removes the containers and
  every volume it made, and undoes what a `finish` wrote to the instance's env files. A hook sets a
  value with `python3 -m pihx.envfile set <file> <NAME> <value>`.

What the entries look like to a user is in [Initializing an instance](restore.md).

### Summary and commands

`summary.sh` is run by `pihx <instance> summary`: it prints `[section]` lines, then one sorted fact per
line, so a before-and-after pair can be diffed. **No secrets and no row contents.**

`commands/<name>` are executable files, run with `pihx <instance> <svc> <name> [args...]` on instances
that have the service. `pihx <instance> <svc>` lists them with the first comment line after the
shebang of each, so write one. A command holds the instance lock while it runs, so no other command
changes the instance meanwhile, unless one of its first ten lines is `# pihx: no-lock`, which a
command that only reads should carry. Its exit status is `pihx`'s.

### What a script's environment holds

Every script (restore hooks, `summary.sh`, commands) runs inside `pihx`'s container with the instance's
merged values as environment variables (the defaults, the `<svc>.env` files and `instance.env`, as
`pihx <instance> config` prints them), plus:

| Variable | |
|---|---|
| `PIHX_INSTANCE`, `PIHX_INSTANCE_DIR` | the instance's name and directory |
| `PIHX_TOOLS`, `PIHX_HOME` | the instance's checkout, and the directory of instances |
| `PIHX_SERVICE` | the script's own service |
| `SERVICE_NAME` | the instance's name, as compose files interpolate it |
| `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, `COMPOSE_ENV_FILES` | so a plain `docker compose ...` targets the instance |

Compose has no variable for the project directory, so pass `--project-directory "$PIHX_INSTANCE_DIR"`
to resolve the compose files' paths as `pihx` does.

**The environment holds the instance's secrets** (database passwords among them). A script must never
print it: no `env`, `set`, `printenv` or `set -x`, and no message that quotes a value.

### Checking a new service

`test/run unit` loads every manifest and checks the conventions above; `test/run static` validates each
service's compose files against its defaults. Give `test/static/services.bats` placeholder values
for what the service requires and has no default for. The static docs test checks the links in the
service's `README.md`.
