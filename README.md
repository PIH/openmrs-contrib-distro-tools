# openmrs-contrib-distro-tools

Tooling for running OpenMRS distributions locally for development or testing, in CI, or on a production machine
Clone it once and use it as a shortcut for common `openmrs-docker` and `openmrs-sdk` workflows.

## Install

### On Linux or macOS

Clone this repo (change the target as appropriate for personal preference) and put its `bin/` directory on `PATH`:

```bash
git clone https://github.com/PIH/openmrs-contrib-distro-tools.git ~/openmrs-contrib-distro-tools
echo 'export PATH="$HOME/openmrs-contrib-distro-tools/bin:$PATH"' >> ~/.bashrc   # bash — use ~/.zshrc for zsh
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

TODO

## Docker (`openmrs-docker`)

### Creating a server instance

Each distribution has its own published Docker image, and its own set of supported PIH_CONFIG profiles.  Refer to the 
distribution-specific README files for these specific options.  Choose the options that best meet your needs for the
type of environment you are setting up:

`IMAGE_NAME` (eg. `partnersinhealth/lesotho-emr`)
`PIH_CONFIG` (eg. `lesotho,lesotho-botsabelo-demo`)

These are the bare minimum required to create an instance.  For additional configuration options, consult the 
usage documentation by running `openmrs-docker` with no arguments.

For example, you can specify a different port for the Tomcat HTTP server by setting the `TOMCAT_HTTP_PORT` environment variable:

**For developers**:  In order for some options to be available that support deployment of uncommited distribution changes, you should also
set the `DISTRO_SOURCE_DIR` environment variable to the path of the distribution you want to use for local builds.

Once you have the appropriate environment variables determined, you pass them to the `openmrs-docker create` command along
with the name of the instance you want to create (this can be any name you like):

```bash
IMAGE_NAME=partnersinhealth/lesotho-emr \
PIH_CONFIG=lesotho,lesotho-botsabelo-demo \
DISTRO_SOURCE_DIR="<path_to_lesotho_emr_src>" \
openmrs-docker create <name> --build
```

Alternatively, you can use the `TEMPLATE` environment variable to specify a pre-existing `env` file to use as a starting point:

```bash
TEMPLATE=/path/to/existing/env/file \
openmrs-docker create <name>
```

Creating a new instance will create a new directory under `$OPENMRS_DOCKER_HOME` on your machine (defaults to `$HOME/openmrs`)
containing the environment configuration and a pre-initialized Docker image.  If you wish to keep your docker instance directories
separate from your openmrs-sdk instance directories, you can set the `$OPENMRS_DOCKER_HOME` environment variable to a different location.

## `env` file reference

| Variable | Required? | Purpose |
|---|---|---|
| `IMAGE_NAME` | Required (unless `TEMPLATE` supplies it) | OpenMRS image, no tag |
| `PIH_CONFIG` | Required (unless `TEMPLATE` supplies it) | PIH config profile for this instance |
| `DISTRO_SOURCE_DIR` | Required for `build`/`--dev`/`--build` only | Path to the distro repo checkout |
| `SEED_IMAGE_NAME` | Optional | Full seed image name (no tag) — used by `start` without `--fresh` |
| `SERVICE_NAME` | Optional (defaults to the instance name) | Docker Compose project name |
| `OPENMRS_IMAGE_TAG`, `SEED_IMAGE_TAG` | Optional (`latest`) | Image tags |
| `TOMCAT_HTTP_PORT`, `MYSQL_PORT`, `TOMCAT_DEBUG_PORT` | Optional | Port overrides — set differently per instance to run more than one at once |
| `TZ` | Optional (`UTC`) | Container timezone |
| `DB_IMAGE`, `OMRS_DB_USER`, `OMRS_DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `ACTIVITYLOG_ENABLED`, `DB_MEMORY_LIMIT`, `OPENMRS_MEMORY_LIMIT`, `OMRS_JAVA_MEMORY_OPTS`, `DB_MAX_ALLOWED_PACKET`, `DB_INNODB_BUFFER_POOL_SIZE` | Optional | Tuning knobs |


### Using a server instance

Once you have created the instance, you can start it up by running the following command:

```bash
openmrs-docker <name> start
```

The first time you start, Docker will download the pre-initialized image from the internet. This can
take 10–20 minutes depending on your connection. Subsequent starts will be much faster.

Once the download is complete, run the following command to be notified when OpenMRS is fully ready:

```bash
openmrs-docker <name> wait
```

When you see **OpenMRS is ready**, open a browser and go to **http://localhost:8080/openmrs** (or
whatever `TOMCAT_HTTP_PORT` that instance was created with, if not the default).

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
  botsabelo-demo:
    if: github.repository_owner == 'PIH'
    concurrency:
      group: build-seeded-images-botsabelo-demo-${{ github.ref }}
      cancel-in-progress: true
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/build-seeded-image.yml@main
    with:
      image_name: partnersinhealth/lesotho-emr
      site: botsabelo-demo
      pih_config: lesotho,lesotho-botsabelo-demo
    secrets: inherit
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | OpenMRS image, no tag |
| `site` | Required | Site name — passed to `openmrs-docker create <site>` |
| `pih_config` | Required | PIH config profile for this site |
| `seed_image_name` | Optional | Full seed image name, no tag. Defaults to `<image_name>-seed-<site>` |

Requires a `DOCKERHUB_PASSWORD` secret available to the caller (passed via `secrets: inherit`).
