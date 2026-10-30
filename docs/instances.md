# Running an instance

An instance is a directory under `PIHX_HOME` (default `~/pihx`) with an env file for each of its
services ([An instance's files](env.md)), run as one Docker Compose project named after the
instance. `pihx` is the general tool. `openmrs-docker` is a `pihx` extension that can be used in
place of `pihx`: it does everything `pihx` does, with the same command line, plus OpenMRS development
commands (OpenMRS's default services, building a distribution from source; [The openmrs-docker
extension](../openmrs/README.md)). Run either with no arguments for every command and option. (`~/openmrs` is the OpenMRS SDK's directory, which is why instances
aren't kept there.)

## Creating an instance

Each distribution has its own published image and, if it uses one, its own PIH config profiles; its
README lists them. `OPENMRS_IMAGE_NAME` is required for an instance with the `openmrs` service.
`OPENMRS_PIH_CONFIG` is optional, since not every distro uses one, but a distro that needs it fails at
startup without it. The instance name is also its Compose project name, so it must be lowercase
letters, digits, `-` and `_`, starting with a letter or digit, and not `list`, `help` or `version`.
`create` takes the values you set in your shell ([An instance's files](env.md#where-values-come-from)):

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci \
OPENMRS_HTTP_PORT=9090 \
openmrs-docker <name> create

# the same with pihx, which needs the services named:
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
pihx <name> create --services=openmrs-db,openmrs
```

A settings file you `export` from and `source` first works too ([An instance's
files](env.md#where-values-come-from)). `--services=<comma-separated>` chooses the services
(`openmrs-docker`'s default is `openmrs-db,openmrs`), and others are added later with
`add-service` ([Services](services.md)). Before the first start, [`initialize`](restore.md) can fill the
instance's volumes from a seed image or a backup, which is much faster than OpenMRS building them up
itself.

## Starting, stopping and logs

```bash
pihx <name> start
pihx <name> wait      # until OpenMRS has started (its /health/started endpoint)
```

When `wait` finishes, go to `http://localhost:8080/openmrs` (or the instance's `OPENMRS_HTTP_PORT`).

```bash
pihx <name> logs [service]   # follow the logs, of every service by default
pihx <name> status           # the containers, and the command holding the lock, if any
pihx <name> stop             # removes the containers; the data stays in the volumes
pihx <name> compose <args>   # inspect with docker compose: `config`, `ps`, `exec openmrs-db sh`, ...
pihx <name> destroy          # removes the containers, the volumes and the instance directory (asks first; refuses a directory without instance.env)
pihx list                    # the instances, with their services and the tools directory each runs
pihx <name> config           # the merged values, secrets masked
```

`restart` restarts the containers in place, so it doesn't pick up changes to the env files; `start`
does.

Each container's log is Docker's, kept and rotated as the host's Docker is set up to (Docker's own
default, `json-file`, doesn't rotate; servers set the `local` driver, which does). It lasts as long as
the container: `stop`, and a `start` or `update` that recreates a container (a new image, a changed
setting), start it over. Keeping logs longer means shipping them off the host.

## Updating

```bash
pihx <name> update    # pulls the latest images, and recreates the containers that changed
```

`update` pulls, brings the instance up (removing the containers of services whose env file is gone),
checks that each service's setup containers succeeded, and then removes the images the recreated
containers were made from, so repeated deploys don't pile them up: one a pull of the same tag
replaced (left untagged), or one a registry has (it can be pulled again), e.g. the previous version
after a tag change. Never a local build still tagged, which no registry may have, nor an image
another container is made from (another instance on the same version): Docker refuses those, and
they're left quietly. `start` removes them too.

An instance runs the service files of its own `tools` directory ([An instance's
files](env.md#the-tools-directory)), so there is nothing to sync: updating the tool updates its
instances, once the containers are recreated.

## Building a distro from source (developers)

`openmrs-docker`: set `OPENMRS_DISTRO_DIR` (at `create`, or later in `openmrs.env`) to the distro's
Maven project (an absolute path), then:

- `start --build` or `update --build` builds the distro (`mvn clean package`, on the host) and its
  image first; `build` does only that.
- `start --dev` or `update --dev` runs the image with what you last built mounted over its distro,
  and with Java debugging on `OPENMRS_DEBUG_PORT`.

## Compose on the instance

`pihx <name> compose <subcommand> [args...]` inspects the instance with `docker compose`, using what
pihx's own commands use: the instance's project name, project directory, env files and compose files.
The subcommand (first, before any option) is one of `config`, `ps`, `images`, `top`, `port`, `logs`,
`events`, `ls`, `version` and `exec`; its arguments go to Compose untouched, and its exit status is
the command's. The others (`up`, `down`, `run`, ...) are refused with the managed command to use,
and so is `config -o`/`--output`, which could overwrite one of the instance's files: redirect the
output instead.

**`compose config` prints every secret unmasked** (passwords in the services' environment), unlike
`pihx <name> config`: don't paste its output anywhere, and delete any copy you redirect it to.

```bash
pihx <name> compose config            # the resolved model: what runs for each service
pihx <name> compose config openmrs    # one service's
pihx <name> compose ps
pihx <name> compose exec openmrs-db sh
```

It doesn't take the instance lock, so use the managed commands to change the instance. Values a service's start script decides (e.g.
`create-tables`) aren't computed, since that could start containers: those variables are passed
empty, as when the script fails, so `config` shows the fail-closed default.

## One command at a time

Every command that changes an instance (`initialize`, `start`, `stop`, `restart`, `update`, `pull`,
`add-service`, `remove-service`, `use-tools`, `destroy`, a job's `run-service` and a service's commands
unless they say `# pihx: no-lock`) holds a lock on it until it exits, and refuses to run while another
command holds it, naming that command:

```
error: <name> is busy: initialize (pid 12345, started 2026-09-30 11:39:19) -- run this again once that finishes.
```

So on a puppet-managed host, the `update` puppet runs on every apply fails, and changes nothing, while an `initialize`, `reset-accounts` or PETL run is in progress. With
`PIHX_LOCK_WAIT=<seconds>` set, a command waits up to that long for the lock instead, and then fails
naming the holder (puppet's deploys wait an hour). A job (PETL) holds the lock for its whole run, so a
deploy can't restart MySQL under a PETL run. Such a run is against the running instance: it runs the
setup services first (account and login setup), and starts, stops or recreates none of the
instance's containers, so `openmrs-db` (and `sqlserver`, if it has one) must be running. It doesn't
need OpenMRS: PETL also runs against restored databases with no OpenMRS. For other services (the
smoke tests) it refuses while the instance is busy but doesn't hold the lock. `status`, `logs`, `compose` and
`wait` never wait for it. The lock is released however its holder exits, so there's nothing to
clean up after a crash. It uses `flock`.

## Changing the database passwords

Editing `OPENMRS_DB_PASSWORD` or `OPENMRS_DB_ROOT_PASSWORD` changes nothing in an existing database by
itself: see [`reset-accounts`](../services/openmrs-db/README.md#changing-the-passwords).

## Updating this tool, and pinning it

The tool is a git clone, so `git pull` in it updates it, and `git checkout <commit/branch/tag>` pins
it. Each instance runs its own `tools` directory, so to keep some instances on a stable
version while you work on the tool in another checkout (e.g. a `git worktree` on `main`), point them
at it with `pihx <name> use-tools <dir>`. The first run with a new version of
`images/pihx-runtime` pulls that image (or builds it, when CI hasn't published it yet).

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
