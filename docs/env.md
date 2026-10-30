# An instance's files

An instance is a directory under `PIHX_HOME` (default `~/pihx`) holding one env file per service,
`instance.env` for the values every service shares, and the `tools` directory it runs.
`pihx <name> create` writes them (Puppet writes them for the instances it manages).

```
~/pihx/lesotho/
  instance.env         TZ
  openmrs-db.env       OPENMRS_DB_PASSWORD, OPENMRS_DB_ROOT_PASSWORD, ports...
  openmrs.env          OPENMRS_IMAGE_NAME, OPENMRS_PIH_CONFIG, OMRS_EXTRA_*, and, from
                       openmrs-docker, OPENMRS_DISTRO_DIR...
  petl.env             (one file per service of the instance)
  openmrs.override.yaml   optional: see below
  .lock                the instance lock
  tools -> /home/me/distro-tools    the tools directory this instance runs
```

## The files present are the instance's services

Adding `petl.env` adds PETL ([`add-service`](services.md#adding-and-removing-services) writes it);
removing a service's file removes the service, when `pihx <name> update` brings the instance up and
removes the containers of services it no longer has. Volumes are kept. A `<name>.env` that is not a
service in the tools directory is an error, naming the file; `instance` is `instance.env`, so it is not a
service name.

## Format

Each line is `KEY='value'`. A single-quoted value is literal to Docker Compose, which reads the files,
and to bash, so passwords can contain `$`, `"`, backticks and backslashes (not one at the very end).
A value can't contain a single quote or a newline: `create` and `add-service` refuse one, naming the
variable. If you edit a file by hand, keep to single quotes: Compose expands `$` references in an
unquoted or double-quoted value.

Each file holds only this instance's values for its service. Defaults are not copied into it: they
stay in the tools directory, in `services/<svc>/env.defaults` ([Writing a
service](services.md#variables-envdefaults-and-the-instances-files)) and `instance.env.defaults`. So
a variable absent from the instance's files has its default, and a new default arrives with the
tools directory.

## Where values come from

- **`create`** writes the values you have set in your shell, each to the file of the service that
  knows it: `instance.env` for a name in `instance.env.defaults` (`TZ`); the service whose
  `env.defaults` defines the name; otherwise the first service, by name, that captures its prefix
  (`OMRS_EXTRA_*` for openmrs, `OPENMRS_DB_OPT_*` for openmrs-db) or whose compose files mention it. A
  variable with no default that a service requires (e.g. `PETL_MYSQL_PASSWORD`) has to be set, or
  `create` and `add-service` refuse, quoting the message. So a settings file you source first works,
  as long as it `export`s each variable (plain `KEY=value` lines only set shell variables, which
  `pihx` never sees):

  ```bash
  # kol-ci.sh
  export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
  export OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci
  export OPENMRS_HTTP_PORT=9090
  ```

  ```bash
  source kol-ci.sh
  pihx lesotho create --services=openmrs-db,openmrs
  ```

  To start from another instance's values, copy its files: `cp ~/pihx/other/*.env ~/pihx/new/` before
  its first start (after editing what must differ, such as ports).
- **Later**, you edit the files, and `pihx <name> config` prints the result, secrets masked
  (`--show-secrets` shows them). Any `pihx` command picks up the change, but a running container only
  does when `start` or `update` recreates it (`restart` doesn't).
- **For one command**, a few values come from your environment instead and are never written
  (`ARCHIVE_PASSWORD`, `PIHX_LOCK_WAIT`...).
  Docker Compose runs with only what `pihx` sets, so your environment never changes an instance's
  values.

## What each container gets

A service's containers get its `env.defaults`, then its `<svc>.env`, and whatever its compose file
passes under `environment:` (`TZ` from `instance.env`; a value another service owns, such as the
database password `openmrs` uses, which stays in the owner's file). Nothing else: there is no
shared file to filter. Compose's own interpolation of the compose files sees every file of the
instance, in this order, later winning: `instance.env.defaults`, each service's `env.defaults`,
each `<svc>.env`, then `instance.env`. Because of that, variable names are prefixed by their
service, and two services never define the same one.

`<svc>.override.yaml` in the instance directory is a compose file applied after that service's own
(and any `with-<other>.yaml`), for one-off changes that aren't env values: an extra port, a debug
mount. It survives updates of the tool.

## The tools directory

`tools` is the directory of this tool that the instance runs: `pihx <name> ...` runs the instance's own
`tools`, whichever `pihx` you typed (the launcher hands off to `tools/bin/pihx`). `create` points it at
the tools directory it was run from. To move an instance to another tools directory, such as a worktree on
a stable branch:

```bash
pihx <name> use-tools <dir>
pihx list        # the instances, their services and their tools directorys
```

## Variables

Each service's variables are in its README ([Services](services.md)). Those of the instance itself:

| Variable | Default | Purpose |
|---|---|---|
| `TZ` | `UTC` | Containers' time zone |

`openmrs-docker` keeps `OPENMRS_DISTRO_DIR`, the distribution's Maven project for `build`, `--build`
and `--dev`, in `openmrs.env` ([The openmrs-docker extension](../openmrs/README.md)).

And these, for one command, from your shell, never in the files:

| Variable | Purpose |
|---|---|
| `PIHX_HOME` | The directory of instances (default `~/pihx`; `~/openmrs` is the OpenMRS SDK's) |
| `PIHX_LOCK_WAIT` | Seconds a command waits for another one holding the instance's lock, instead of refusing at once ([One command at a time](instances.md#one-command-at-a-time)) |
| `PIHX_WAIT_TIMEOUT` | Seconds `wait` waits (default 3600) |
| `PIHX_DEBUG` | `1` prints the traceback of an unexpected error, which is otherwise one `error:` line, and echoes each `docker` and `docker compose` command line pihx runs to stderr, before it runs, prefixed `+ ` (values aren't on them, except what you type yourself: `run-service` and `compose exec` arguments) |
| `PIHX_INITIALIZE_TIMEOUT`, `ARCHIVE_PASSWORD`, `OPENMRS_DATA_OWNER`, `SKIP_DISK_SPACE_CHECK` | `initialize` ([Initializing an instance](restore.md)) |
