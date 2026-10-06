# Optional services

Besides `openmrs-db` and `openmrs`, `docker/services/` has OpenHIM and its mediators, the AdvaPACS
gateway, PETL, SQL Server, and the smoke tests ([CI workflows](ci-workflows.md#running-smoke-tests-locally)).

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
doesn't bring up: run it with `openmrs-docker <name> run-service [--pull] <svc> [command...]`
(`--pull` pulls its image first; a plain `pull` skips profiled services).

## MySQL accounts

`openmrs-db`'s fragment has a one-shot `openmrs-db-accounts`. On every `start`, and first for any
service that depends on it, it makes sure each account declared in `env` exists:

```
OPENMRS_DB_ACCOUNT_<ID>_USER='<user>'
OPENMRS_DB_ACCOUNT_<ID>_PASSWORD='<password>'
OPENMRS_DB_ACCOUNT_<ID>_GRANTS='<privileges> ON <db>.<table>[;<privileges> ON <db>.<table>...]'
OPENMRS_DB_ACCOUNT_<ID>_DATABASES='<db> ...'   # optional: created if missing
```

It creates `<user>@'%'` if missing, sets its password to the one in `env` (so a rotated password, or a
restored database's old one, is replaced), creates the databases and applies the grants. A
declaration missing a value changes nothing; anything else wrong fails with MySQL's own error. Either
way its log (`openmrs-docker <name> logs openmrs-db-accounts`) says why. Accounts that aren't declared, and the same user's accounts for other
hosts, are left alone: removing one is up to you. `root` and the OpenMRS account (`OPENMRS_DB_USER`) can't be declared: their passwords are the instance's own (`OPENMRS_DB_*`). If it fails, so do `start` and `update`, naming it,
and a lock-holding `run-service` (petl) doesn't run. A service can declare its own account in its
`.env.defaults`, as petl does.

## OpenHIM and mediators

`openhim` is the standard OpenHIM install (MongoDB, openhim-core and openhim-console). Each mediator is
its own fragment, and more than one can be attached to the same OpenHIM.

OpenHIM's MongoDB database is named `openhim` (it was `openhim-development` before TASKS-596). An
instance created before starts on an empty database: `openhim-setup` sets the admin password again
and each mediator registers and provisions its channels and clients on its next start, but the
transaction log, audit events, metrics and anything changed by hand in the console aren't carried
over. The old database stays in the `mongo-data` volume, to copy with `mongodump` / `mongorestore
--nsFrom 'openhim-development.*' --nsTo 'openhim.*'` or drop.

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

For example, with the proxy serving the console at `https://openhim.example.org` and forwarding
`/api` there to the admin API: `OPENHIM_CONSOLE_API_PROTOCOL=https`,
`OPENHIM_CONSOLE_API_HOST=openhim.example.org`, `OPENHIM_CONSOLE_API_PORT=443`,
`OPENHIM_CONSOLE_API_PATH=/api`, `OPENHIM_CONSOLE_URL=https://openhim.example.org`.

Logging in to the console needs that proxy, serving the admin API over HTTPS. openhim-core's session
cookie is Secure, and core trusts the proxy's `X-Forwarded-Proto` to know the request came in over
HTTPS. Caddy sends it by default; behind nginx, add `proxy_set_header X-Forwarded-Proto $scheme;`.
Without it, or with the browser going straight to the published port, every login fails, and
openhim-core logs "Cannot send secure cookie over unencrypted connection".

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

## AdvaPACS gateway

`advapacs-gateway` is AdvaPACS's on-premises gateway, from its
[`advahealthsolutions/advapacs-gateway`](https://hub.docker.com/r/advahealthsolutions/advapacs-gateway)
image ([AdvaPACS's install guide](https://docs.advapacs.com/getting-started/connect-modalities/install-the-gateway/docker)).
It receives studies from the site's modalities over DICOM (and HL7, if set up) and uploads them to
AdvaPACS, connecting out over HTTPS only. It doesn't need `openhim` or the mediator: the mediator
carries orders, the gateway carries images.

Create the gateway in AdvaPACS (Configuration > Gateways > +), which shows its region and access
key; the secret is shown only once.

| Variable | Default | |
|---|---|---|
| `ADVAPACS_GATEWAY_REGION` | must be set | the gateway's region |
| `ADVAPACS_GATEWAY_ACCESS_KEY_ID` | must be set | the gateway's access key ID |
| `ADVAPACS_GATEWAY_ACCESS_KEY_SECRET` | must be set | the gateway's access key secret |
| `ADVAPACS_GATEWAY_IMAGE_NAME`, `ADVAPACS_GATEWAY_IMAGE_TAG` | `advahealthsolutions/advapacs-gateway`, `1.21.1` | to upgrade, change the tag in the instance's `env` and run `update` |

Everything else is configured in AdvaPACS, and the gateway picks it up within a few minutes of
starting, when it shows as Online:

- **Ports.** Each Local AE (Configuration > Local AEs) and each gateway HL7 inbound service has its
  own port, which the gateway opens. The gateway uses the host's network, so these are the host's
  ports: nothing is published, but the host's firewall must let the modalities reach them. Give
  modalities the host's IP address, with the Local AE's AE title and port, and check with a C-ECHO.
- **Modalities.** Each one is a Remote AE (Configuration > Remote AEs), whose AE title must match the
  modality's exactly, case included. Its worklist and query settings are there too.
- **Data directory.** Leave it at the default, `/opt/AdvaHealthSolutions/AdvaPACSGateway`: that's the
  `advapacs-gateway-data` volume, which holds received studies until they're uploaded.

AdvaPACS asks for 4 GB of memory (8 GB recommended) and 50 GB of disk (200 GB recommended) for the
gateway, and an accurate clock (NTP): its authentication fails if the host's clock drifts.

```bash
export ADVAPACS_GATEWAY_REGION=<region>
export ADVAPACS_GATEWAY_ACCESS_KEY_ID=<access-key-id>
export ADVAPACS_GATEWAY_ACCESS_KEY_SECRET=<access-key-secret>
openmrs-docker <name> add-service advapacs-gateway
openmrs-docker <name> start
```

## SQL Server

`sqlserver` is Microsoft's SQL Server (`mcr.microsoft.com/mssql/server:2025-latest`;
`SQLSERVER_IMAGE_TAG`), with its data in the `sqlserver-data` volume. Its one-shot `sqlserver-setup`
runs on every `start`, and first for any service that depends on it:

- server settings: SIMPLE recovery for new databases, cost threshold for parallelism 25, max degree
  of parallelism 0, max server memory `SQLSERVER_MEMORY_MB` (2048), at least `SQLSERVER_TEMPDB_FILES`
  (4) tempdb files;
- each database in `SQLSERVER_DATABASES` (space-separated), created if missing;
- each login declared in `env`, created if missing, its password kept to the one in `env`, and a user
  with the role in each of its databases (created if missing; an existing user, e.g. in a database
  restored from another server, is remapped to this server's login):

```
SQLSERVER_LOGIN_<ID>_USER='<login>'
SQLSERVER_LOGIN_<ID>_PASSWORD='<password>'
SQLSERVER_LOGIN_<ID>_DATABASES='<db> ...'
SQLSERVER_LOGIN_<ID>_ROLE='db_owner'          # the default
```

As for MySQL accounts, logins that aren't declared are left alone, anything wrong fails with SQL
Server's own error, and a failure stops `start`, `update` and a lock-holding `run-service`. SQL
Server's policy also refuses a password containing its login's name. `sa` can't be declared (it's the
server's admin, set by `SQLSERVER_SA_PASSWORD`). `SQLSERVER_SA_PASSWORD` has no default; SQL Server needs passwords of at least 8 characters,
with three of upper case, lower case, digits and symbols. The instance's services reach it on 1433;
`SQLSERVER_PUBLISHED_PORT` (default 1433, or `<address>:<port>`) is where it's reachable from outside
Docker, e.g. for reporting tools. `SQLSERVER_MEMORY_LIMIT` (3g) is the container's memory limit.

`sqlserver` replaces `petl-sqlserver`. To move an instance that has it: `openmrs-docker <name>
remove-service petl-sqlserver`, then with `SQLSERVER_SA_PASSWORD` and `PETL_MYSQL_PASSWORD` set in your
shell, `openmrs-docker <name> add-service sqlserver` and `openmrs-docker <name> sync` (the newer petl
fragment). Then, in `env`:

- set `PETL_SQLSERVER_HOST='sqlserver'`;
- set `PETL_SQLSERVER_USER='petl'` and `PETL_MYSQL_USER='petl'`: older instances have `sa` and the
  OpenMRS account there, and `sa` can't be a declared login;
- add the `OPENMRS_DB_ACCOUNT_PETL_*` and `SQLSERVER_LOGIN_PETL_*` lines from
  `docker/services/petl.env.defaults`, with the same users and passwords.

Then run PETL to rebuild the data (or copy it from the `petl-sqlserver-data` volume yourself).

## PETL

`petl` runs the [petl](https://github.com/PIH/petl) ETL pipeline against the instance's `openmrs-db`,
writing to SQL Server. It's a job: run it with `openmrs-docker <name> run-service --pull petl`. Its
image is an ETL project's (e.g. `partnersinhealth/ces-etl`, `partnersinhealth/apzu-etl`), built on
`partnersinhealth/petl` with that project's jobs, datasources and `application.yml`; it runs
`PETL_FULL_REFRESH_JOBS`, retrying up to `PETL_MAX_RETRIES` times, then exits.

Its runs reuse one container, `<name>-petl`, kept between them and recreated only when its image or
settings change, so its log builds up across runs like a running service's: `openmrs-docker <name>
logs petl` (it follows: Ctrl-C), or `docker logs <name>-petl`. `docker inspect -f '{{.State.ExitCode}}
{{.State.FinishedAt}}' <name>-petl` gives the last run's result. `stop` removes the container (and
its log). `run-service petl <command...>` runs that command in a one-off container instead.

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/ces-emr
export PETL_IMAGE_NAME=partnersinhealth/ces-etl
export PETL_FULL_REFRESH_JOBS="create-partitions.yml refresh-cesci-data.yml"
export PETL_MYSQL_PASSWORD=<pick-a-password>
export PETL_SQLSERVER_PASSWORD=<pick-a-password>
export SQLSERVER_SA_PASSWORD=<pick-a-password>
export PETL_SQLSERVER_DATABASE=openmrs_ces_ci
export SERVICES=openmrs-db,openmrs,petl,sqlserver
openmrs-docker create <name>
openmrs-docker <name> start
openmrs-docker <name> run-service --pull petl
```

- **Configuration:** the petl container gets `env`'s `PETL_*`, `DATASOURCES_*`, `SPRING_*` and
  `LOGGING_*` lines. PETL reads any of its properties by its Spring environment-variable name (`.` and
  `-` become `_`, uppercased), so e.g. `DATASOURCES_OPENMRS_CESCI_HOST` sets
  `datasources.openmrs.cesci.host`, overriding the image's `application.yml`.
- **Its accounts:** PETL connects to MySQL as `PETL_MYSQL_USER` (`petl`) and to SQL Server as
  `PETL_SQLSERVER_USER` (`petl`). `PETL_MYSQL_PASSWORD` has no default and must be set.
  `PETL_SQLSERVER_PASSWORD` is needed only by an ETL that writes to SQL Server (not, e.g., an
  apzu-etl run filling only its MySQL reporting database); with `sqlserver` in the instance,
  `sqlserver-setup` refuses to start without it (`SQLSERVER_LOGIN_PETL_PASSWORD must be set`).
  ETL projects' datasource files paste these into YAML unquoted, so keep them to letters, digits
  and `-`, `_`, `.`, `+`, `=`, `~` (a ` #` cuts one short; `: ` or a leading `"`, `!`, `&`, `*`,
  `%`, `@`, `[`, `{` breaks the file). petl's defaults declare the matching MySQL account (`OPENMRS_DB_ACCOUNT_PETL_*`, `ALL ON
  *.*`) and SQL Server login (`SQLSERVER_LOGIN_PETL_*`, `db_owner` on `PETL_SQLSERVER_DATABASE`,
  default `openmrs_reporting`), and petl waits for both setups before it runs. If you change a PETL
  user or password in `env`, change its `OPENMRS_DB_ACCOUNT_PETL_*` or `SQLSERVER_LOGIN_PETL_*` line
  too.
- **MySQL connection options:** `PETL_MYSQL_OPTIONS`, which ETL projects' `application-docker.yml`
  uses for their MySQL datasources. The default (the legacy servers' options) ends with
  `serverTimezone=${user.timezone}`, which PETL resolves to its JVM's zone, the instance's `TZ`.
  Keep `serverTimezone` if you change the options: without it, PETL's MySQL driver goes by the
  server's zone abbreviation, refusing some (e.g. `EDT`) and misreading others (`CST` as Chicago,
  an hour off from Mexico City for part of the year).
- **A MySQL reporting database:** only for an ETL with a MySQL reporting stage (apzu-etl):
  `PETL_MYSQL_REPORTING_DATABASE` is created and granted to PETL's account.
- **Job history:** by default PETL keeps it in H2, in the `petl-data` volume. To keep it in SQL Server
  instead (tables `petl_database_change_log*` and `petl_job_execution` in its database, where reports
  and monitoring can read them, as on the legacy test and production servers), add to `env`:

  ```
  SPRING_DATASOURCE_URL='jdbc:sqlserver://sqlserver:1433;databaseName=<PETL_SQLSERVER_DATABASE>'
  SPRING_DATASOURCE_USERNAME='<PETL_SQLSERVER_USER>'
  SPRING_DATASOURCE_PASSWORD='<PETL_SQLSERVER_PASSWORD>'
  SPRING_DATASOURCE_DRIVER_CLASS_NAME='com.microsoft.sqlserver.jdbc.SQLServerDriver'
  SPRING_DATASOURCE_PLATFORM='mssql'
  SPRING_JPA_HIBERNATE_DIALECT='org.hibernate.dialect.SQLServer2012Dialect'
  SPRING_LIQUIBASE_DATABASE_CHANGE_LOG_TABLE='petl_database_change_log'
  SPRING_LIQUIBASE_DATABASE_CHANGE_LOG_LOCK_TABLE='petl_database_change_log_lock'
  ```

  (puppet's `openmrs_docker::service::petl` writes these with `job_store => 'sqlserver'`).
- **A remote SQL Server:** without the `sqlserver` service, set `PETL_SQLSERVER_HOST` and
  `PETL_SQLSERVER_PORT` (defaults `sqlserver`, 1433), the user and the password; the login has to
  exist there.
- **Runs and deploys:** a `run-service petl` holds the instance's lock for the whole run, so a
  deploy (`pull`, `start`, ...) waits for it or refuses. It runs against the running instance:
  `openmrs-db` (and `sqlserver`, if the instance has it) must be up, OpenMRS needn't be
  ([One command at a time](instances.md#one-command-at-a-time)).
