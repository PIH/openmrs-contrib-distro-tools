# The OpenMRS front end (`openmrs-docker`)

`bin/openmrs-docker` keeps today's `openmrs-docker` command line on top of `pihx`. It is a launcher
like `bin/pihx` (it runs [`front.py`](front.py) through `bin/pihx`, in `pihx-runtime`), and its
instances are `pihx` instances: they live under `PIHX_HOME` (default `~/pihx`), and
`pihx <name> <command>` works on them too.

What it adds to `pihx`:

| `openmrs-docker` | `pihx` |
|---|---|
| `create <name>`, with `SERVICES` (default `openmrs-db,openmrs`); `OPENMRS_IMAGE_NAME` required with `openmrs` | `<name> create --services=...` |
| `<name> start` / `update [--build] [--dev]`, `<name> build` | `start` / `update`, with the overlays below |
| `<name> initialize` with `RESTORE_*` / `SEED_IMAGE_NAME` | `initialize --from <folder>` / `--from-image <image>` |
| `<name> fingerprint [--data-dir] [--exclude-distribution-artifacts] [--output=<file>]` | `summary` (only openmrs-db's, and openmrs's with `--data-dir`) |
| `<name> reset-openmrs-db-accounts` | `<name> openmrs-db reset-accounts` |
| `<name> wait` | `wait`, saying whether OpenMRS is ready |
| `<name> sync` | nothing: instances use their checkout's service files directly |

Everything else (`list`, `stop`, `restart`, `status`, `logs`, `pull`, `add-service`,
`remove-service`, `run-service`, `destroy`) is `pihx`'s command. `run-service` also passes, for that
run, the values you set for the service's own variables that the instance doesn't set (e.g. the
smoke tests' `SMOKE_TESTS_*`), as `openmrs-docker` always took them from the shell.

## Values only the front end uses

`create` writes these to the instance's `instance.env` when they're set in your environment; their
defaults are here, not in a service's:

| Variable | Default | Used by |
|---|---|---|
| `DISTRO_SOURCE_DIR` | none | `build`, `--build`, `--dev`: the distribution's source checkout |
| `SEED_IMAGE_NAME` | none | `initialize`: a seed image, for what no `RESTORE_*` variable restores |
| `SEED_IMAGE_TAG` | `latest` | `initialize` |

`initialize` takes the instance's `SEED_IMAGE_*`, or else yours. `INITIALIZE_DB_TIMEOUT` sets
`pihx`'s `PIHX_INITIALIZE_TIMEOUT`.

## initialize's RESTORE_* variables

Each one becomes an entry of a temporary `--from` folder under `PIHX_HOME`, named as the service's
manifest accepts it: a link to the path (Docker resolves it on the host), or a copy where a link
can't be made. A volume with no `RESTORE_*` source comes from the seed image, if there is one.

| Variable | Entry |
|---|---|
| `RESTORE_MYSQL_DUMP_PATH` | `openmrs-db.sql`, `.sql.gz`, `.sql.7z` or `.sql.zip` |
| `RESTORE_MYSQL_DATA_PATH` | `openmrs-db.datadir/` |
| `RESTORE_MYSQL_PERCONA_PATH` | `openmrs-db.percona/`, or `.percona.7z`/`.zip`/`.tar.gz`/`.tgz`/`.tar` |
| `RESTORE_OPENMRS_DATA_PATH` | `openmrs/`, or `openmrs.7z`/`.zip`/`.tar.gz`/`.tgz`/`.tar` |

Exactly one database source is needed (a `RESTORE_MYSQL_*` variable or the seed image). `bin/pihx`
resolves each path on the host and mounts it, read-only, when it's outside the paths it always
mounts.

## Overlays: modes/

Compose files the front end adds to the instance's for one command:

- [`modes/dev.yaml`](modes/dev.yaml), for `--dev`: mounts the distribution built in
  `DISTRO_SOURCE_DIR` over the image's, and publishes the Java debug port (`OPENMRS_DEBUG_PORT`).
- [`modes/build.yaml`](modes/build.yaml), for `build` and `--build`: builds the openmrs image from
  that distribution. `bin/openmrs-docker` first runs `mvn clean package -U` in `DISTRO_SOURCE_DIR`,
  on the host (Maven and Java are needed there), and `bin/pihx` mounts the directory read-only, for
  Compose to send as the build context.

## Seed images: seed/

[`seed/Dockerfile`](seed/Dockerfile) builds a distribution's seed image
(`.github/workflows/build-seeded-image.yml`): a `/seed` folder with `openmrs-db.sql.gz` and
`openmrs.tar.gz`, as `initialize --from-image` restores them.

## Setting up a machine: setup.sh

[`setup.sh`](setup.sh) sets up Ubuntu (e.g. under WSL) with git and Docker, clones the tools and
puts `bin/` on the `PATH` (see the [README](../README.md)).
