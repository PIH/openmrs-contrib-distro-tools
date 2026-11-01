# petl

[petl](https://github.com/PIH/petl), the ETL pipeline, run against the instance's `openmrs-db`,
writing to SQL Server. It's a job (`job: true` in its manifest): `pihx <name> start` doesn't bring it
up, and `pihx <name> run-service --pull petl` runs it. Its image is an ETL project's (e.g.
`partnersinhealth/ces-etl`, `partnersinhealth/apzu-etl`), built on `partnersinhealth/petl` with that
project's jobs, datasources and `application.yml`; it runs `PETL_FULL_REFRESH_JOBS`, retrying up to
`PETL_MAX_RETRIES` times, then exits. Settings are in `petl.env`; defaults are in
[`env.defaults`](env.defaults).

Its runs reuse one container, `<name>-petl`, kept between them and recreated only when its image or
settings change, so its log builds up across runs like a running service's: `pihx <name> logs petl`
(it follows: Ctrl-C), or `docker logs <name>-petl`. `docker inspect -f '{{.State.ExitCode}}
{{.State.FinishedAt}}' <name>-petl` gives the last run's result. `stop` removes the container (and
its log). When a run recreates it, the image it was made from is removed, as `update` does
([Updating](../../docs/instances.md#updating)). `run-service petl <command...>` runs that command in
a one-off container instead.

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/ces-emr
export PETL_IMAGE_NAME=partnersinhealth/ces-etl
export PETL_FULL_REFRESH_JOBS="create-partitions.yml refresh-cesci-data.yml"
export PETL_MYSQL_PASSWORD=<pick-a-password>
export PETL_SQLSERVER_PASSWORD=<pick-a-password>
export SQLSERVER_SA_PASSWORD=<pick-a-password>
export PETL_SQLSERVER_DATABASE=openmrs_ces_ci
openmrs-docker <name> create --services=openmrs-db,openmrs,petl,sqlserver
openmrs-docker <name> start
openmrs-docker <name> run-service --pull petl
```

- **Configuration:** the petl container gets the whole of `petl.env` and the service's defaults, so
  `PETL_*`, `DATASOURCES_*`, `SPRING_*` and `LOGGING_*` lines all reach it. PETL reads any of its
  properties by its Spring environment-variable name (`.` and `-` become `_`, uppercased), so e.g.
  `DATASOURCES_OPENMRS_CESCI_HOST` sets `datasources.openmrs.cesci.host`, overriding the image's
  `application.yml`. At `create`, `PETL_*`, `DATASOURCES_*`, `SPRING_*` and `LOGGING_*` set in your
  shell go into `petl.env`.
- **Its accounts:** PETL connects to MySQL as `PETL_MYSQL_USER` (`petl`) and to SQL Server as
  `PETL_SQLSERVER_USER` (`petl`). `PETL_MYSQL_PASSWORD` has no default and must be set.
  `PETL_SQLSERVER_PASSWORD` is needed only by an ETL that writes to SQL Server (not, e.g., an
  apzu-etl run filling only its MySQL reporting database); with `sqlserver` in the instance,
  `sqlserver-setup` refuses to start without it (`SQLSERVER_LOGIN_PETL_PASSWORD must be set`).
  ETL projects' datasource files paste these into YAML unquoted, so keep them to letters, digits
  and `-`, `_`, `.`, `+`, `=`, `~` (a ` #` cuts one short; `: ` or a leading `"`, `!`, `&`, `*`,
  `%`, `@`, `[`, `{` breaks the file). With `openmrs-db` in the instance,
  [`with-openmrs-db.yaml`](with-openmrs-db.yaml) declares PETL's MySQL account from `PETL_MYSQL_*`
  (`OPENMRS_DB_ACCOUNT_PETL_*`, `ALL ON *.*`), and with `sqlserver`,
  [`with-sqlserver.yaml`](with-sqlserver.yaml) declares its login from `PETL_SQLSERVER_*`
  (`SQLSERVER_LOGIN_PETL_*`, `db_owner` on `PETL_SQLSERVER_DATABASE`, default `openmrs_reporting`).
  Both are `x:-y` defaults, so an `OPENMRS_DB_ACCOUNT_PETL_*` or `SQLSERVER_LOGIN_PETL_*` line in
  `petl.env` overrides them. PETL waits for both setups before it runs.
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
  and monitoring can read them, as on the legacy test and production servers), add to `petl.env`:

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
  ([One command at a time](../../docs/instances.md#one-command-at-a-time)).
