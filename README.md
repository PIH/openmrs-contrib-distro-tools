# openmrs-contrib-distro-tools

Tools for running OpenMRS distributions in Docker: for development and testing on your own machine,
in CI, and on servers.

- **`pihx`** creates and runs *instances*: a set of services (an OpenMRS database and OpenMRS, OpenHIM
  and its mediators, PETL and SQL Server, the AdvaPACS gateway and others) as one Docker Compose
  project. Each service is a directory in this repo that holds everything about it; an instance is a
  directory of one env file per service. `pihx` needs only Docker and a shell.
- **`openmrs-docker`** is a `pihx` extension for OpenMRS development. It can be used in place of
  `pihx`: it does everything `pihx` does, with the same command line, plus OpenMRS development
  commands. It creates an instance with OpenMRS and its database by default, and builds a
  distribution from source and runs it.
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

Open a new terminal, and `pihx`, `openmrs-docker`, `openmrs-utils` and `openmrs-sdk` are available. You
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
curl -fsSL https://raw.githubusercontent.com/PIH/openmrs-contrib-distro-tools/main/setup.sh | bash
```

When the process is complete, close the Ubuntu terminal window and relaunch it from the Start Menu.
You only need to do this once — `openmrs-contrib-distro-tools` is now installed and on your `PATH`.

## Quick start

Create an instance of an OpenMRS distro (OpenMRS and its database, `openmrs-docker`'s default), fill
it from the distro's nightly seed image, and start it:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci \
openmrs-docker lesotho create

openmrs-docker lesotho initialize --from-image partnersinhealth/lesotho-emr-seed-lesotho
openmrs-docker lesotho start
openmrs-docker lesotho wait        # until OpenMRS has started
```

Then go to `http://localhost:8080/openmrs`. Instances live in `~/pihx` (`PIHX_HOME`; `~/openmrs`
is the OpenMRS SDK's), and `pihx` works on them directly: `openmrs-docker` is `pihx` with an
extension, and `pihx` is what servers use. Afterwards (`openmrs-docker` works in place of `pihx`
in each):

```bash
pihx lesotho logs        # follow the logs
pihx lesotho status      # the containers, and what holds the instance's lock
pihx lesotho update      # pull the images, and recreate what changed
pihx lesotho stop        # the data stays in the instance's volumes
pihx lesotho destroy     # removes the instance and its data
pihx list                # every instance
```

`pihx` creates an instance of the services you name, here the same one:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr \
OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci \
pihx lesotho2 create --services=openmrs-db,openmrs
pihx lesotho2 start
```

Run `pihx`, `openmrs-docker` or `openmrs-utils` with no arguments for every command and option.

## Documentation

| | |
|---|---|
| [Running an instance](docs/instances.md) | Creating, starting, updating and pinning instances; the instance lock |
| [An instance's files](docs/env.md) | `instance.env` and one env file per service: where values come from, what a container sees, overrides, the tools directory an instance runs |
| [Services](docs/services.md) | The services, adding and removing them, and how to write one; each service's README has its variables |
| [Initializing an instance](docs/restore.md) | Filling a new instance from a seed image, dumps, data directories or Percona backups, and checking the result |
| [The openmrs-docker extension](openmrs/README.md) | `openmrs-docker`: what it adds to `pihx`, building and running a distro from source |
| [Utilities](docs/utilities.md) | `openmrs-utils`: backups, restores and checks, and the images they run |
| [CI workflows](docs/ci-workflows.md) | The reusable workflows: build and release, base image variants, seed images, smoke tests, scanning; and the helper images this repo publishes |
| [The openmrs-sdk wrapper](docs/sdk.md) | `openmrs-sdk` commands |
| [Developing this tool](docs/development.md) | Code layout, image tags and the test suite |
