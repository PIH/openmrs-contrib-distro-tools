# Optional services

Besides `openmrs-db` and `openmrs`, `docker/services/` has OpenHIM and its mediators, PETL and its
SQL Server, and the smoke tests ([CI workflows](ci-workflows.md#running-smoke-tests-locally)).

## Attaching a service

Choose an instance's services with `SERVICES=<comma-separated>` at `create` (default
`openmrs-db,openmrs`), or attach and detach one later:

```bash
openmrs-docker <name> add-service <svc>
openmrs-docker <name> remove-service <svc>
```

Each service is a fragment, `docker/services/<svc>.yaml`, with its defaults in `<svc>.env.defaults`,
which `create` and `add-service` write into the instance's `env` ([The env file](env.md)).
`add-service` refuses a fragment whose services don't fit the instance's others (e.g. a mediator
without `openhim`), and changes nothing. `remove-service` removes only that fragment's containers,
and keeps its volumes, naming them. A profiled service (PETL, the smoke tests) is a job that `start`
doesn't bring up: run it with `openmrs-docker <name> run-service <svc> [command...]`.

## OpenHIM and mediators

`openhim` is the standard OpenHIM install (MongoDB, openhim-core and openhim-console). Each mediator is
its own fragment, and more than one can be attached to the same OpenHIM.

OpenHIM's clients authenticate with Basic auth or custom tokens; its JWT authentication is off,
since nothing uses it and it would otherwise accept a token signed with a shared secret for any
client.

Inside the instance's Docker network, OpenHIM and its mediators talk plain HTTP, including
openhim-core's admin API; TLS for access from outside is the reverse proxy's job. `openhim.yaml`
publishes only what's used from outside, and its comments say why each one is:

| Variable | Default | Published for |
|---|---|---|
| `OPENHIM_CONSOLE_HOST_PORT` | `9000` | the admin console |
| `OPENHIM_ADMIN_API_HOST_PORT` | `8081` | the admin API, which the console (running in the admin's browser) calls directly |
| `OPENHIM_ROUTER_HTTP_HOST_PORT` | `5001` | the router, for external systems calling a channel. A proxy in front should forward only those channels' paths: some channels are public |

Behind a proxy, tell the console where the browser finds the admin API, and set the console's own
address for links openhim-core generates. The defaults are for a browser on the same machine:

| Variable | Default |
|---|---|
| `OPENHIM_CONSOLE_API_PROTOCOL`, `OPENHIM_CONSOLE_API_HOST`, `OPENHIM_CONSOLE_API_PORT`, `OPENHIM_CONSOLE_API_PATH` | `http`, `localhost`, `OPENHIM_ADMIN_API_HOST_PORT`, empty |
| `OPENHIM_CONSOLE_URL` | `http://localhost:<OPENHIM_CONSOLE_HOST_PORT>` |

OpenHIM's MongoDB database is named `openhim` (it was `openhim-development` before TASKS-596). An
instance created before starts on an empty database: `openhim-setup` sets the admin password again
and each mediator registers and provisions its channels and clients on its next start, but the
transaction log, audit events, metrics and anything changed by hand in the console aren't carried
over. The old database stays in the `mongo-data` volume, to copy with `mongodump` / `mongorestore
--nsFrom 'openhim-development.*' --nsTo 'openhim.*'` or drop.

For example, with the proxy serving the console at `https://openhim.example.org` and forwarding
`/api` there to the admin API: `OPENHIM_CONSOLE_API_PROTOCOL=https`,
`OPENHIM_CONSOLE_API_HOST=openhim.example.org`, `OPENHIM_CONSOLE_API_PORT=443`,
`OPENHIM_CONSOLE_API_PATH=/api`, `OPENHIM_CONSOLE_URL=https://openhim.example.org`.

The following example will create an instance with OpenHIM and its mediators installed, configured
for Lesotho:

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
export OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci
export SEED_IMAGE_NAME="partnersinhealth/lesotho-emr-seed-lesotho"
export OPENHIM_PASSWORD=<pick-a-password>
export ADVAPACS_MEDIATOR_INBOUND_SECRET=<pick-a-secret>
export ADVAPACS_MEDIATOR_OPENHIM_INBOUND_CLIENT_PASSWORD=<pick-a-password>
export ADVAPACS_CLIENT_ID=<advapacs-client-id>
export ADVAPACS_CLIENT_SECRET=<advapacs-client-secret>
export OPENMRS_USERNAME=<username-for-mediator-access-to-openmrs>
export OPENMRS_PASSWORD=<password-for-mediator-access-to-openmrs>
export ADVAPACS_PATIENT_IDENTIFIER_SYSTEM="http://www.pih.org/identifiers/lesotho/emr-id"
export SERVICES=openmrs-db,openmrs,openhim,openhim-advapacs-mediator
openmrs-docker create <name>
openmrs-docker <name> initialize
openmrs-docker <name> start
```

## PETL and its SQL Server

- **`petl`** runs the [petl](https://github.com/PIH/petl) ETL pipeline against the instance's
  `openmrs-db`. It's a job, so run it with `run-service petl`; it needs `PETL_IMAGE_NAME`.
- **`petl-sqlserver`** is the SQL Server petl writes to, from Microsoft's
  `mcr.microsoft.com/mssql/server` image. A one-shot `petl-sqlserver-init` creates the
  `PETL_SQLSERVER_DATABASE` database (default `openmrs_reporting`) once SQL Server is up.

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
export PETL_IMAGE_NAME=partnersinhealth/petl
export PETL_SQLSERVER_PASSWORD=<pick-a-password>
export SERVICES=openmrs-db,openmrs,petl,petl-sqlserver
openmrs-docker create <name>
openmrs-docker <name> start
openmrs-docker <name> run-service petl
```

`PETL_SQLSERVER_PASSWORD` has no default: `create` and `add-service` refuse without it. SQL Server
needs it to be at least 8 characters, with three of upper case, lower case, digits and symbols.

- **petl and petl-sqlserver together:** petl writes to `petl-sqlserver`, on 1433 inside the
  instance. `PETL_SQLSERVER_PUBLISHED_PORT` (default 1433) is where it's reachable on this machine
  from outside Docker, e.g. for reporting tools, like `OPENMRS_DB_PORT` for `openmrs-db`.
- **petl alone:** petl writes to a SQL Server elsewhere: set `PETL_SQLSERVER_HOST` and
  `PETL_SQLSERVER_PORT` to it (defaults: `petl-sqlserver`, 1433), and the user and password.

Before, `PETL_SQLSERVER_PORT` was also petl-sqlserver's published port, so moving that port broke
petl. On an instance from then, `sync` sets `PETL_SQLSERVER_PUBLISHED_PORT` from it; then remove
`PETL_SQLSERVER_PORT` from env, or set it to 1433.
