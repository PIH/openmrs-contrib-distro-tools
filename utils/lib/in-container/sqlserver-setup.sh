#!/bin/bash
# Runs inside the SQL Server image as sqlserver-setup (sqlserver.yaml), once sqlserver is healthy:
#   - server settings, as PIH's legacy sqlserver module: SIMPLE recovery for new databases, cost
#     threshold for parallelism 25, max degree of parallelism 0, max server memory
#     (SQLSERVER_MEMORY_MB), at least SQLSERVER_TEMPDB_FILES tempdb data files (the image may already
#     have made one per CPU, up to 8);
#   - each database in SQLSERVER_DATABASES and in any login's _DATABASES, created if missing (SIMPLE);
#   - each login declared as SQLSERVER_LOGIN_<ID>_USER, _PASSWORD, _DATABASES, _ROLE (db_owner):
#     created if missing, its password set on every run, a user in each of its databases with the role.
# Everything is checked first: a bad declaration changes nothing. Undeclared logins are left alone.
#   SQLCMDPASSWORD  sa's password (required)
set -euo pipefail
: "${SQLCMDPASSWORD:?}"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# The script on stdin, so passwords stay off the command line.
run_sql() { "$SQLCMD" -C -S sqlserver -U sa -b -h -1 -W -i /dev/stdin <<< "SET NOCOUNT ON; $1"; }
q() { printf "N'%s'" "${1//\'/\'\'}"; }   # an N'...' string literal

ident='^[A-Za-z0-9_]+$'
errors=()
[[ "${SQLSERVER_MEMORY_MB:-}" =~ ^[0-9]+$ ]] || errors+=("SQLSERVER_MEMORY_MB must be a number of MB")
[[ "${SQLSERVER_TEMPDB_FILES:-}" =~ ^[1-9][0-9]?$ ]] || errors+=("SQLSERVER_TEMPDB_FILES must be 1-99")
for db in ${SQLSERVER_DATABASES:-}; do [[ "$db" =~ $ident ]] || errors+=("SQLSERVER_DATABASES: '$db' isn't a plain database name"); done
ids=$(compgen -v | sed -n 's/^SQLSERVER_LOGIN_\(.*\)_\(USER\|PASSWORD\|DATABASES\|ROLE\)$/\1/p' | sort -u)
for id in $ids; do
    p="SQLSERVER_LOGIN_${id}"; u="${p}_USER" pw="${p}_PASSWORD" d="${p}_DATABASES" r="${p}_ROLE"
    [[ "$id" =~ $ident ]] || errors+=("$p: the id must be letters, digits and _")
    [[ "${!u:-}" =~ $ident ]] || errors+=("$u must be set, to letters, digits and _")
    [ -n "${!pw:-}" ] || errors+=("$pw must be set")
    [[ "${!pw:-}" != *\\* ]] || errors+=("$pw can't contain a backslash")
    [ -n "${!d:-}" ] || errors+=("$d must list at least one database")
    for db in ${!d:-}; do [[ "$db" =~ $ident ]] || errors+=("$d: '$db' isn't a plain database name"); done
    [[ "${!r:-db_owner}" =~ $ident ]] || errors+=("$r isn't a plain role name")
done
if [ ${#errors[@]} -gt 0 ]; then
    printf 'error: %s\n' "${errors[@]}" "nothing was changed" >&2
    exit 1
fi

run_sql "ALTER DATABASE model SET RECOVERY SIMPLE"
run_sql "EXEC sp_configure 'show advanced options', 1; RECONFIGURE"
run_sql "EXEC sp_configure 'cost threshold for parallelism', 25; RECONFIGURE"
run_sql "EXEC sp_configure 'max degree of parallelism', 0; RECONFIGURE"
run_sql "EXEC sp_configure 'max server memory (MB)', $SQLSERVER_MEMORY_MB; RECONFIGURE"
for i in $(seq 2 "$SQLSERVER_TEMPDB_FILES"); do
    run_sql "IF NOT EXISTS (SELECT 1 FROM tempdb.sys.database_files WHERE name = 'tempdev$i')
        ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev$i', FILENAME = '/var/opt/mssql/data/tempdb$i.ndf', SIZE = 256MB, FILEGROWTH = 64MB)"
done
echo "Server settings applied"

dbs="${SQLSERVER_DATABASES:-}"
for id in $ids; do d="SQLSERVER_LOGIN_${id}_DATABASES"; dbs+=" ${!d}"; done
for db in $(tr ' ' '\n' <<< "$dbs" | sed '/^$/d' | sort -u); do
    run_sql "IF DB_ID($(q "$db")) IS NULL BEGIN CREATE DATABASE [$db]; ALTER DATABASE [$db] SET RECOVERY SIMPLE; END"
    echo "Database $db ready"
done

for id in $ids; do
    p="SQLSERVER_LOGIN_${id}"; u="${p}_USER" pw="${p}_PASSWORD" d="${p}_DATABASES" r="${p}_ROLE"
    login=${!u} role=${!r:-db_owner}
    run_sql "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $(q "$login"))
        CREATE LOGIN [$login] WITH PASSWORD = $(q "${!pw}")
    ELSE ALTER LOGIN [$login] WITH PASSWORD = $(q "${!pw}")"
    echo "Login $login ready"
    for db in ${!d}; do
        run_sql "USE [$db]; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = $(q "$login"))
            CREATE USER [$login] FOR LOGIN [$login]; ALTER ROLE [$role] ADD MEMBER [$login]"
        echo "$login is $role in $db"
    done
done
