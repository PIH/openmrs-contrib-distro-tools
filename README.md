# openmrs-contrib-distro-tools

Tools for running OpenMRS distributions in Docker: for development and testing on your own machine,
in CI, and on servers.

- **`openmrs-docker`** creates and runs *instances*: an OpenMRS distro image with its MySQL database
  and, optionally, OpenHIM and its mediators, PETL and others, as one Docker Compose project. It
  can fill a new instance from a seed image or from a server's backups.
- **`openmrs-utils`** runs standalone utilities for backing up, restoring and checking MySQL
  databases and OpenMRS data directories, on an instance or on a server installed directly on a host.
- **`openmrs-sdk`** wraps common OpenMRS SDK commands, for distro development without Docker images.
- **Reusable GitHub Actions workflows** that build, release, seed, smoke-test and scan distro images.

## Install

### On Linux or macOS

Clone this repo (anywhere you like) and put its `bin/` directory on `PATH`:

```bash
export DISTRO_TOOLS_HOME=~/code/github/pih/openmrs-contrib-distro-tools
git clone https://github.com/PIH/openmrs-contrib-distro-tools.git "$DISTRO_TOOLS_HOME"
echo "export PATH=\"$DISTRO_TOOLS_HOME/bin:\$PATH\"" >> ~/.bashrc   # ~/.zshrc for zsh
```

Open a new terminal, and `openmrs-docker`, `openmrs-utils` and `openmrs-sdk` are available. You
need Docker with the Compose plugin, 2.20 or later. To update the tool, `git pull` in it.

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

## Quick start

Create an instance of a distro, fill it from the distro's nightly seed image, and start it:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci \
SEED_IMAGE_NAME=partnersinhealth/lesotho-emr-seed-lesotho \
openmrs-docker create lesotho

openmrs-docker lesotho initialize
openmrs-docker lesotho start
openmrs-docker lesotho wait        # until OpenMRS has started
```

Then go to `http://localhost:8080/openmrs`. Afterwards:

```bash
openmrs-docker lesotho logs        # follow the logs
openmrs-docker lesotho stop        # the data stays in the instance's volumes
openmrs-docker lesotho destroy     # removes the instance and its data
```

Run `openmrs-docker` or `openmrs-utils` with no arguments for every command and option.

## Documentation

| | |
|---|---|
| [Running an instance](docs/instances.md) | Creating, starting, updating and building instances; the instance lock; changing DB passwords |
| [The env file](docs/env.md) | An instance's settings: where they come from, every variable, database server options, runtime properties |
| [Initializing an instance](docs/restore.md) | Filling a new instance from a seed image, dumps, data directories or Percona backups, and checking the result |
| [Utilities](docs/utilities.md) | `openmrs-utils`: backups, restores and checks |
| [Optional services](docs/services.md) | OpenHIM and its mediators, PETL and its SQL Server |
| [CI workflows](docs/ci-workflows.md) | The reusable workflows: build and release, base image variants, seed images, smoke tests, scanning |
| [The openmrs-sdk wrapper](docs/sdk.md) | `openmrs-sdk` commands |
| [Developing this tool](docs/development.md) | Code layout and the test suite |
