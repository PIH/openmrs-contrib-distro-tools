# openmrs

The OpenMRS application, from `OPENMRS_IMAGE_NAME` (a distribution's image), with its data in the
`openmrs-data` volume. It requires `openmrs-db`. Settings are in the instance's `openmrs.env`;
defaults are in [`env.defaults`](env.defaults).

| Variable | Default | |
|---|---|---|
| `OPENMRS_IMAGE_NAME` | none: must be set | the distribution's image, no tag (e.g. `partnersinhealth/lesotho-emr`) |
| `OPENMRS_IMAGE_TAG` | `latest` | e.g. `latest-java8` for a base image variant ([CI workflows](../../docs/ci-workflows.md#base-image-variants)) |
| `OPENMRS_PIH_CONFIG` | empty | PIH config profiles, for a distro that uses them (e.g. `lesotho,lesotho-kol-ci`); OpenMRS fails at startup if it needs one and this is missing |
| `OPENMRS_HTTP_PORT`, `OPENMRS_DEBUG_PORT` | `8080`, `1044` | published ports; set them differently to run more than one instance at once |
| `OPENMRS_MEMORY_LIMIT`, `OPENMRS_JAVA_MEMORY_OPTS` | `4g`, `-Xms512m -Xmx2g -XX:NewSize=128m` | memory |
| `OPENMRS_ACTIVITYLOG_ENABLED` | `false` | |
| `OPENMRS_CREATE_TABLES` | unset | `true` or `false` overrides whether OpenMRS creates its tables. Unset, pihx decides at each `start` and `update` ([below](#creating-the-tables)) |
| `OMRS_EXTRA_*`, `OMRS_JAVA_SERVER_OPTS` | none | runtime properties and Java options ([below](#runtime-properties-omrs_extra_)) |

The database password and user come from `openmrs-db.env`: `openmrs` doesn't redefine them.

## Creating the tables

OpenMRS creates its tables (`create_tables`) only when it has just been found to have none. Before
every `pihx <name> start` and `update`, [`start/create-tables`](start/create-tables) (the manifest's
`start-env`) starts `openmrs-db` and counts, as root, the tables in the OpenMRS schema. A count of
zero gives true, for that start only; anything else -- tables, a failed or timed-out query,
`openmrs-db` not healthy, unexpected output -- gives false, with a line saying why. Nothing is
recorded, and a plain `docker compose up` that bypasses pihx gets false. `OPENMRS_CREATE_TABLES`
in `openmrs.env`, if set, decides instead.

It decides only when there is no `openmrs` container. While one exists, in any state, a start or
update keeps the value that container has (read with `docker inspect`), so this value never
recreates it: a recreate part way through OpenMRS's first install could leave a half-built schema
that the next start would take for an installed one. If that value can't be read, it's false, with
a warning. `pihx <name> stop` removes the container, so the start after it decides from the
database again.

## Runtime properties (`OMRS_EXTRA_*`)

openmrs-core's `startup-init.sh` turns each `OMRS_EXTRA_<name>` into a runtime property: the name is
lowercased, `_` becomes `.` and `__` becomes `_` (so `OMRS_EXTRA_pihmalawi_warehouse_connection_url`
sets `pihmalawi.warehouse.connection.url`). Property keys with capital letters can't be set this way.
At `create`, `OMRS_EXTRA_*` set in your shell go into `openmrs.env` (the manifest's `capture-env`);
later, add them there, and `pihx <name> start` picks them up (`restart` doesn't).

Distro images already set some of these: the OpenMRS SDK's `build-distro` bakes each `property.<key>`
from `openmrs-distro.properties` into the image as `ENV OMRS_EXTRA_<key with . replaced by _>`, e.g.
`OMRS_EXTRA_pih_config` and `OMRS_EXTRA_initializer_startup_load`. To override one of those, use
exactly that name, including its case. Environment variable names are case-sensitive, so
`OMRS_EXTRA_INITIALIZER_STARTUP_LOAD` would be a second variable for the same property rather than an
override, and on a first install openmrs-core keeps the image's value. Check an image's baked values
with `docker image inspect <image> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep OMRS_EXTRA_`.

openmrs-core 2.6+ writes the runtime properties file once, on its first install, and afterwards only
merges `OMRS_EXTRA_*` into it. For anything else in an existing file, see
[`runtime-properties`](../../docs/utilities.md).

## Restoring and summarizing

`initialize` restores `openmrs-data` from the entries `openmrs.7z`, `.tar.gz`, `.tgz`, `.tar`, `.zip`
or `openmrs/`; its `restore/prepare` finds the owner to give the files (the image's runtime user,
or `OPENMRS_DATA_OWNER`), and what else happens to a restored data directory is in
[Initializing an instance](../../docs/restore.md#openmrs-data-after-a-restore).
`pihx <name> summary` includes the data directory's files per folder, without what the distribution
supplies (modules, owa, configuration, frontend) unless `--include-distribution-artifacts`.
