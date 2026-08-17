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
| `PIH_CONFIG` | _(required)_ | PIH config profile passed to SDK setup, e.g. `<config>,<config>-<site>` |
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

Each distribution has its own published Docker image, and its own set of supported PIH config profiles.  Refer to the 
distribution-specific README files for these specific options.  Choose the options that best meet your needs for the
type of environment you are setting up:

`OPENMRS_IMAGE_NAME` (eg. `partnersinhealth/lesotho-emr`)
`OPENMRS_PIH_CONFIG` (eg. `lesotho,lesotho-kol-ci`)

These are the bare minimum required to create an instance.  For additional configuration options, consult the 
usage documentation by running `openmrs-docker` with no arguments.

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
| `OPENMRS_PIH_CONFIG` | Required | PIH config profile for this instance |
| `DISTRO_SOURCE_DIR` | Required for `build`/`--dev`/`--build` only | Path to the distro repo checkout |
| `SEED_IMAGE_NAME` | Required for `initialize` only | Full seed image name (no tag) |
| `SERVICE_NAME` | Optional (defaults to the instance name) | Docker Compose project name |
| `OPENMRS_IMAGE_TAG`, `SEED_IMAGE_TAG` | Optional (`latest`) | Image tags |
| `OPENMRS_HTTP_PORT`, `OPENMRS_DB_PORT`, `OPENMRS_DEBUG_PORT` | Optional | Port overrides — set differently per instance to run more than one at once |
| `TZ` | Optional (`UTC`) | Container timezone |
| `OPENMRS_DB_IMAGE_NAME` (`mysql`), `OPENMRS_DB_IMAGE_TAG` (`5.6`), `OPENMRS_DB_USER`, `OPENMRS_DB_PASSWORD`, `OPENMRS_DB_ROOT_PASSWORD`, `OPENMRS_ACTIVITYLOG_ENABLED`, `OPENMRS_DB_MEMORY_LIMIT`, `OPENMRS_MEMORY_LIMIT`, `OPENMRS_JAVA_MEMORY_OPTS`, `OPENMRS_DB_MAX_ALLOWED_PACKET`, `OPENMRS_DB_INNODB_BUFFER_POOL_SIZE` | Optional | Tuning knobs |

### Initializing a server

If you have never started the server before, you can dramatically speed up the initial startup process 
by initializing the database first from a seed image that is built nightly for each supported configuration profile.
These will be documented in each distribution's README and requires an additional `SEED_IMAGE_NAME` and optional `SEED_IMAGE_TAG` environment variable.
Running this command will start the services and populate their volumes with data from the seed image.

```bash
openmrs-docker <name> initialize
```

NOTE: This command is only supported immediately after the instance is created.  If it has previously been started, this
command will fail so as not to overwrite any existing data.

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
    secrets: inherit
```

`permissions: contents: write` is required because `release:prepare` pushes commits and a tag to the default branch. In a reusable-workflow call, the effective token permissions are governed by the caller — a called workflow's own `permissions:` block can only narrow, never widen — so this must be declared here.

Requires `SONATYPE_USERNAME`, `SONATYPE_PASSWORD`, `SONATYPE_GPG_PASSPHRASE`, and `SONATYPE_GPG_PRIVATE_KEY` secrets available to the caller (passed via `secrets: inherit`).

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
      site: kol-ci
      pih_config: lesotho,lesotho-kol-ci
    secrets: inherit
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | OpenMRS image, no tag |
| `site` | Required | Site name — passed to `openmrs-docker create <site>` |
| `pih_config` | Required | PIH config profile for this site |
| `seed_image_name` | Optional | Full seed image name, no tag. Defaults to `<image_name>-seed-<site>` |

Requires a `DOCKERHUB_PASSWORD` secret available to the caller (passed via `secrets: inherit`).
