# The openmrs-sdk wrapper

The `openmrs-sdk` command is a thin wrapper around the OpenMRS SDK itself.  It is not a replacement
for the SDK but rather a convenient way to run common commands.  One can choose to use it or choose
to just use the SDK directly. If choosing to use the SDK directly, inspecting the openmrs-sdk script
will give you a good idea of what the native commands should be.

The `openmrs-sdk` command should be invoked using the following syntax:

```bash
ENV1=VAL1 ENV2=VAL2 openmrs-sdk <command> <server-id>
```

The server ID is a name of your choosing — it controls the server directory
(`~/openmrs/<server-id>`) and, by default, the database name. It can also be set via the `SERVER_ID`
environment variable instead of passed positionally. Because `create`/`update`/`update-config` build
from source, run `openmrs-sdk` from the root of the distribution repo you want to build, or set
`DISTRO_SOURCE_DIR` to point at it.

## `create`

Sets up a new SDK server: builds the distribution from source and runs the OpenMRS SDK setup wizard
non-interactively, producing a local Tomcat server backed by a MySQL database (by default, a Docker
container the SDK manages itself).  The following environment variables are supported by this
command and should be set if any of the listed defaults are not suitable for one's setup.

| Variable | Default | Purpose |
|---|---|---|
| `PIH_CONFIG` | _(optional)_ | PIH config profile passed to SDK setup, e.g. `<config>,<config>-<site>` — leave unset for a distro that doesn't use one; if it does and this is missing, OpenMRS setup fails, not this command |
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

The most common scenario is that one has their own MySQL Docker container running on their local
machine, where they managed their own databases, and do not have the SDK create these directly.  In
this case, one needs to specify the `DB_CONTAINER` environment variable to point to the container,
and any other thoe other `DB_*` variables if the defaults do not match one's setup.

Running from the root of this the distribution repository:

```bash
PIH_CONFIG=<specific-pih-config-setting-to-use> \
DB_CONTAINER=<my-mysql-container-name> \
DB_PORT=<my-mysql-container-port> \> \
DB_USER=root \
DB_PASSWORD=<my-mysql-root-password> \
openmrs-sdk create <server-id>
```

## `update`

Rebuilds the content package and distribution from source and redeploys the updated artifacts to an
existing server.

| Variable | Default | Purpose |
|---|---|---|
| `DISTRO_SOURCE_DIR` | current directory | Path to the distro repo checkout to build |

```bash
openmrs-sdk update <server-id>
```

## `update-config`

Same as `update`, but builds and deploys content/configuration only, skipping the full distribution
build. This is intended to be fast to allow for rapid iteration and testing of content changes.

| Variable | Default | Purpose |
|---|---|---|
| `DISTRO_SOURCE_DIR` | current directory | Path to the distro repo checkout to build |

```bash
openmrs-sdk update-config <server-id>
```

NOTE: This will not automatically include updates made to openmrs-config-pihemr.  One first needs to
run a `mvn clean install` on that project before running this command to incorporate any local
changes made to that project.  One could combine these commands as follows, assuming the
openmrs-config-pihemr project is checked out in the same directory as the distribution repo:

```bash
mvn clean install -f ../openmrs-config-pihemr/pom.xml && openmrs-sdk update-config <server-id>
```

## `run`

Starts the server (Ctrl+C to stop).

| Variable | Default | Purpose |
|---|---|---|
| `JMX_PORT` | _(disabled)_ | Enable JMX remote monitoring on this port |

```bash
openmrs-sdk run <server-id>
```

## `destroy`

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
