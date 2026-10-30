# openmrs-docker: the OpenMRS pihx extension

`openmrs-docker` can be used in place of `pihx`. It does everything `pihx` does, with the same command
line, plus OpenMRS development commands. `bin/openmrs-docker` runs
[`extension.py`](extension.py) through `bin/pihx`, in `pihx-runtime`, as
`PIHX_EXTENSION=openmrs.extension`; its instances are `pihx` instances, under `PIHX_HOME` (default
`~/pihx`), and `pihx <name> <command>` works on them too.

What it adds or changes (`openmrs-docker help` lists them after `pihx`'s commands):

| Command | What the extension does |
|---|---|
| `<name> create [--services=a,b]` | `--services` defaults to `openmrs-db,openmrs`; with `openmrs`, `OPENMRS_IMAGE_NAME` must be set, and `OPENMRS_DISTRO_DIR` (if set) is written to `openmrs.env` |
| `<name> start` / `update [--build] [--dev]` | `--build` and `--dev` add the overlays below; without them it's `pihx`'s |
| `<name> build` | Builds the distribution and its OpenMRS image from `OPENMRS_DISTRO_DIR` |
| `<name> initialize --from-image <image>` | `pihx`'s, and says when the image is probably an old-format seed |

Every other command is `pihx`'s own, unchanged: a command `pihx` gains works here too. There are no
old command names or orders:

| Instead of | Use |
|---|---|
| `openmrs-docker create <name>`, `SERVICES=...` | `openmrs-docker <name> create [--services=...]` |
| `initialize` with `RESTORE_*` variables | `initialize --from <folder>`, the folder holding an entry per service (see [docs/restore.md](../docs/restore.md)) |
| `initialize` with `SEED_IMAGE_NAME` / `SEED_IMAGE_TAG` | `initialize --from-image <name>:<tag>` |
| `INITIALIZE_DB_TIMEOUT` | `PIHX_INITIALIZE_TIMEOUT` |
| `<name> fingerprint` | `<name> summary` (openmrs-db's, then openmrs-data's without the distribution artifacts; `--include-distribution-artifacts` adds them) |
| `<name> reset-openmrs-db-accounts` | `<name> openmrs-db reset-accounts` |
| `<name> sync` | nothing: instances use their checkout's service files directly |
| `SMOKE_TESTS_*` set for one `run-service` | set them when adding the service (`add-service openmrs-smoke-tests`), or in `openmrs-smoke-tests.env` |

## OPENMRS_DISTRO_DIR

The path to the OpenMRS distribution's Maven project (an absolute path), which `build`, `--build`
and `--dev` use. `create` writes it to the instance's `openmrs.env` when it's set in your
environment; edit it there afterwards. Only the extension reads it.

## Overlays: modes/

Compose files the extension adds to the instance's for one command:

- [`modes/dev.yaml`](modes/dev.yaml), for `--dev`: mounts the distribution built in
  `OPENMRS_DISTRO_DIR` over the image's, and publishes the Java debug port (`OPENMRS_DEBUG_PORT`).
- [`modes/build.yaml`](modes/build.yaml), for `build` and `--build`: builds the openmrs image from
  that distribution. `bin/openmrs-docker` first runs `mvn clean package -U` in `OPENMRS_DISTRO_DIR`
  on the host (Maven and Java are needed there), and passes the directory to
  `bin/pihx` to mount read-only (`PIHX_EXTRA_MOUNTS`), for Compose to send as the build context.
  Before Maven runs, the command is checked (its options, the openmrs service, and that nothing
  holds the instance's lock), so one that would be refused doesn't wait for the build. The lock
  itself is only taken after the build: a command that takes it meanwhile makes this one refuse
  then, with the distribution already built.

## Seed images: seed/

[`seed/Dockerfile`](seed/Dockerfile) builds a distribution's seed image
(`.github/workflows/build-seeded-image.yml`): a `/seed` folder with `openmrs-db.sql.gz` and
`openmrs.tar.gz`, as `initialize --from-image` restores them.

## Setting up a machine: setup.sh

[`setup.sh`](setup.sh) sets up Ubuntu (e.g. under WSL) with git and Docker, clones the tools and
puts `bin/` on the `PATH` (see the [README](../README.md)).
