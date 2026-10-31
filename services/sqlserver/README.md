# sqlserver

Microsoft's SQL Server (`mcr.microsoft.com/mssql/server`, tag `SQLSERVER_IMAGE_TAG`, default
`2025-latest`), with its data in the `sqlserver-data` volume. Settings are in `sqlserver.env`;
defaults are in [`env.defaults`](env.defaults). Its one-shot `sqlserver-setup` runs on every `start`
and `update`, and first for any service that depends on it:

- server settings: SIMPLE recovery for new databases, cost threshold for parallelism 25, max degree
  of parallelism 0, max server memory `SQLSERVER_MEMORY_MB` (2048), at least `SQLSERVER_TEMPDB_FILES`
  (4) tempdb files;
- each database in `SQLSERVER_DATABASES` (space-separated), created if missing;
- each login declared for it, created if missing, its password kept to the declared one, and a user
  with the role in each of its databases (created if missing; an existing user, e.g. in a database
  restored from another server, is remapped to this server's login):

```
SQLSERVER_LOGIN_<ID>_USER='<login>'
SQLSERVER_LOGIN_<ID>_PASSWORD='<password>'
SQLSERVER_LOGIN_<ID>_DATABASES='<db> ...'
SQLSERVER_LOGIN_<ID>_ROLE='db_owner'          # the default
```

As for [MySQL accounts](../openmrs-db/README.md#mysql-accounts), logins that aren't declared are left
alone, anything wrong fails with SQL Server's own error, and a failure stops `start`, `update` and a
lock-holding `run-service`. A service's login belongs in its own `with-sqlserver.yaml`, as
[petl's](../petl/with-sqlserver.yaml) is. `sa` can't be declared (it's the server's admin, set by
`SQLSERVER_SA_PASSWORD`).

Passwords must meet SQL Server's policy (`CHECK_POLICY`):

- at least 8 characters;
- characters from at least 3 of 4 sets: upper case, lower case, digits and symbols (anything else);
- not containing the login's name, in any case (`Petl-pass1` for `petl` is refused).

`sqlserver-setup` checks every declared login's password, and the `sa` password (the name rule doesn't
apply to it), before creating or altering anything. On a failure it prints a line naming the login and
variable and the rule broken (never the password), and exits non-zero.

| Variable | Default | |
|---|---|---|
| `SQLSERVER_SA_PASSWORD` | must be set | the `sa` password: at least 8 characters, with 3 of upper case, lower case, digits and symbols (policy above) |
| `SQLSERVER_PUBLISHED_PORT` | `1433` | where it's reachable from outside Docker (e.g. for reporting tools): the port, or `<address>:<port>`. The instance's services reach it on 1433 |
| `SQLSERVER_DATABASES` | empty | databases to create |
| `SQLSERVER_MEMORY_MB`, `SQLSERVER_MEMORY_LIMIT` | `2048`, `3g` | SQL Server's max server memory, and the container's memory limit |
| `SQLSERVER_TEMPDB_FILES` | `4` | |
| `SQLSERVER_IMAGE_TAG` | `2025-latest` | |

`sqlserver` replaces the older `petl-sqlserver`, which `pihx` doesn't have. An instance that had it
keeps PETL values that no longer fit: set `PETL_SQLSERVER_USER` and `PETL_MYSQL_USER` to `petl` (older
instances had `sa` and the OpenMRS account there, and `sa` can't be a declared login) and
`PETL_SQLSERVER_HOST` to `sqlserver` ([PETL](../petl/README.md)). Run PETL again to rebuild the
data (or copy it from the `petl-sqlserver-data` volume yourself).
