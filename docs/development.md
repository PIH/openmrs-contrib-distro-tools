# Developing this tool

## Code layout

- `bin/openmrs-docker` parses the command line, loads the instance, and calls the command's function
  (`cmd_<command>`) in `lib/openmrs-docker/`: `env.sh` (the env file and per-container env files),
  `compose.sh` (running Compose, the instance lock), `instance.sh` (create, list, sync, add/remove a
  service, destroy), `stack.sh` (start, stop, logs, wait, ...), `initialize.sh` and `db.sh`.
- `utils/` holds the standalone utilities, and `utils/lib/` the helpers they (and `openmrs-docker`)
  share; `utils/lib/in-container/` holds scripts that run inside a container.
- `docker/services/` holds the service fragments and their `.env.defaults`, and `docker/modes/` the
  overlays `initialize` and `--dev` add.

## Testing this project

The `test/` directory holds a [bats](https://github.com/bats-core/bats-core) test suite for this
project's own scripts, run by `.github/workflows/test.yml` on every push and pull request that
touches `bin/`, `lib/`, `utils/`, `docker/`, `test/`, `docs/` or the README. Run it locally with:

```bash
test/run                 # everything
test/run static          # shellcheck, Compose validation of every fragment and overlay, doc links (seconds)
test/run args            # argument validation and safety checks (seconds)
test/run integration     # backup -> restore -> verify round trips against real containers (minutes)
test/run integration/dump.bats -f '7z'   # one file, filtered by test name
```

It needs Docker, git, jq, curl and perl: `test/run` fetches pinned versions of bats and GNU parallel
into `test/.deps/` on first use, and falls back to the `koalaman/shellcheck-alpine` image if
`shellcheck` isn't installed. Tests run in parallel, `TEST_JOBS` at a time (default: the number of
CPUs, up to 8; `TEST_JOBS=1` runs them one at a time); with 8 jobs the whole suite takes about a
minute and a half. Tests create everything under a unique name prefix (throwaway
`OPENMRS_DOCKER_HOME`, random host ports, a placeholder OpenMRS image -- `initialize` only ever
starts the database) and remove it all afterwards, so they don't touch existing instances.
