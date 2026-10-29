# Developing this tool

## Code layout

- `bin/pihx` is a short POSIX-sh launcher. It runs the `pihx` Python package from the checkout inside
  the `pihx-runtime` image (Python, the Docker CLI and the Compose plugin), with the checkout and
  `PIHX_HOME` mounted at their own paths so bind mounts resolve on the host, the Docker socket, and
  the caller's uid and terminal. `pihx <instance> ...` hands off to the instance's own checkout
  (`tools`). The host needs only Docker and a shell. The runtime image is pulled by its content tag
  (below), or built when CI hasn't published it yet.
- `pihx/` is the core, which knows nothing about any product: `instance.py` (the directory and its
  files), `envfile.py` (the env file format), `services.py` (manifests), `compose.py` (running
  Compose on an instance), `lock.py`, `script.py` (running a service's scripts) and `commands/`
  (`instance_cmds.py`, `lifecycle.py`, `initialize.py`, `summary.py`, `wait.py`, `service_cmds.py`).
- `services/<svc>/` holds everything of one service: manifest, compose file, env defaults,
  restore overlays, summary and commands ([Writing a service](services.md#writing-a-service)). Its
  README is its docs.
- `bin/openmrs-docker` and `openmrs/` are the OpenMRS front end ([README](../openmrs/README.md)): the
  launcher does what needs the host (resolving `RESTORE_*` paths, running Maven), and
  `openmrs/front.py` runs through the same launcher as a module of `pihx`'s runtime. `openmrs/` also
  holds the compose overlays for `--dev` and `build` (`modes/`), the seed image's Dockerfile and
  `setup.sh`.
- `bin/openmrs-utils` and `utils/` are the standalone Bash utilities, which run on the host and also
  work against legacy servers; `utils/lib/` holds their shared helpers and `utils/lib/in-container/`
  the scripts that run inside a container. `bin/openmrs-sdk` wraps the OpenMRS SDK.
- `images/<name>/` holds images this repo builds, `lib/image-tag.sh` computes their tags, and
  `instance.env.defaults` the values every instance starts from.

## Image tags

An image built from this repo is `partnersinhealth/<name>:<tag>`, where the tag is a content hash
of its folder: `lib/image-tag.sh <dir>` prints the first 12 hex digits of the sha256 of the sorted
`<sha256>  <path>` lines of every file in it. Only content and paths count, so CI and every checkout
compute the same tag, and a change to the folder is a new tag, never an overwritten one. `bin/pihx`
runs `partnersinhealth/pihx-runtime:<tag of images/pihx-runtime>`, never `latest`, so a checkout
always runs the image that matches its source. After a change to `images/pihx-runtime`, the first run
builds the new image locally (CI publishes it when the change reaches `main`).

`.github/workflows/build-images.yml` publishes them: [Helper images](ci-workflows.md#helper-images).

## Testing this project

There are three layers, each run by `test/run`, which needs Docker, git, jq, curl and perl: it fetches
pinned versions of [bats](https://github.com/bats-core/bats-core) and GNU parallel into `test/.deps/`
on first use, and falls back to the `koalaman/shellcheck-alpine` image if `shellcheck` isn't installed.

```bash
test/run unit            # Python unit tests (pihx/tests, openmrs/tests), in pihx-runtime
test/run static          # shellcheck, Compose validation of every service, doc links (seconds)
test/run args            # argument validation and safety checks, with stubs (seconds)
test/run integration     # backup -> restore -> verify and instance round trips against real containers (minutes)
test/run all             # everything: unit first
test/run integration/dump.bats -f '7z'   # one file, filtered by test name
```

- **unit** tests the Python code, and checks every manifest and the conventions of the whole services
  tree (`pihx/tests/test_service_tree.py`). It runs in the `pihx-runtime` image, so it needs only Docker.
- **static** and **args** are bats tests of the scripts and the command line that don't need
  real containers: `static` includes `docs.bats`, which checks that every relative link in the README,
  `docs/`, `openmrs/README.md` and every service's README resolves, headings included; `args` includes the
  launcher (`pihx-launcher.bats`) and the build step of `build-images.yml` run with a stub `docker`.
- **integration** drives `pihx` and `openmrs-docker` as a user would, against real Docker, and the
  utilities against real databases.

Tests run in parallel, `TEST_JOBS` at a time (default: the number of CPUs, up to 8; `TEST_JOBS=1`
runs them one at a time). Tests create everything under a unique name prefix (a throwaway `PIHX_HOME`,
random host ports, a placeholder OpenMRS image -- `initialize` only ever starts the database) and
remove it all afterwards, so they don't touch existing instances.

`.github/workflows/test.yml` runs `unit`, `static`, `args` and `integration` on pushes to `main` and on pull
requests that touch `bin/`, `lib/`, `utils/`, `pihx/`, `services/`, `openmrs/`, `images/`,
`instance.env.defaults`, `test/`, `docs/` or the README.
