#!/bin/bash
# `pihx <instance> summary`: the [sqlserver] section, each table's row count in each database the
# backups service backs up (SQLSERVER_BACKUP_DATABASES; none, nothing is printed: the others are
# usually rebuilt, so comparing them says nothing about a restore). From the running server if there
# is one; otherwise from the stopped instance's sqlserver-data volume, with a throwaway server of the
# instance's own image (on an internal network; a minute or so to start), e.g. right after
# `initialize`, shut down cleanly after. sa's password goes by name (SQLCMDPASSWORD,
# MSSQL_SA_PASSWORD), never on a command line. Run through pihx, which sets the environment
# (pihx/script.py).
set -euo pipefail
read -r -a databases <<< "${SQLSERVER_BACKUP_DATABASES:-}"
[ ${#databases[@]} -gt 0 ] || exit 0
for db in "${databases[@]}"; do
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || { echo "error: SQLSERVER_BACKUP_DATABASES: '$db' isn't a database name" >&2; exit 1; }
done
export SQLCMDPASSWORD="$SQLSERVER_SA_PASSWORD" MSSQL_SA_PASSWORD="$SQLSERVER_SA_PASSWORD"
sql() { # <container> <query>
    # -m 1: no informational messages (e.g. "Changed database context").
    docker exec -e SQLCMDPASSWORD "$1" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b -m 1 -h -1 -W \
        -s ' ' -Q "SET NOCOUNT ON; $2"
}
names=$(printf ",'%s'" "${databases[@]}"); names=${names#,}
# A chosen database that isn't there is a line of its own, so a diff shows it.
summarize() { # <container>
    echo "[sqlserver]"
    for db in "${databases[@]}"; do
        if [ "$(sql "$1" "SELECT COUNT(*) FROM sys.databases WHERE name = '$db'")" = 0 ]; then
            echo "missing $db"
            continue
        fi
        sql "$1" "USE [$db]; SELECT 'rows', '$db.' + s.name + '.' + t.name, SUM(p.row_count)
                  FROM sys.dm_db_partition_stats p JOIN sys.tables t ON t.object_id = p.object_id
                  JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE p.index_id IN (0, 1)
                  GROUP BY s.name, t.name"
    done | LC_ALL=C sort
}

container="$SERVICE_NAME-sqlserver"
if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; then
    summarize "$container"
    exit 0
fi
volume="${SERVICE_NAME}_sqlserver-data"
docker volume inspect "$volume" >/dev/null 2>&1 || {
    echo "error: $volume doesn't exist -- nothing to summarize" >&2
    exit 1
}
temp="$SERVICE_NAME-summary-sqlserver"
# On a network of its own that reaches nothing (--internal), publishing nothing: with --network none,
# each login takes minutes.
network="$SERVICE_NAME-summary"
# Shut down cleanly (SQL Server ignores SIGTERM, so `docker stop` alone kills it after its timeout),
# so the real start that follows needs no crash recovery; one left by an interrupted summary first.
stop_temp() {
    sql "$temp" "SHUTDOWN" >/dev/null 2>&1 || true
    docker stop -t 60 "$temp" >/dev/null 2>&1 || true
    docker rm -f "$temp" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
}
stop_temp
if [ -n "$(docker ps -q --filter "volume=$volume")" ]; then
    echo "error: a container is using $volume -- two servers on one data directory corrupt it" >&2
    exit 1
fi
trap stop_temp EXIT
docker network create --internal "$network" >/dev/null
# The instance's own memory settings, as compose.yaml gives the real server.
docker run -d --name "$temp" --network "$network" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD \
    -e MSSQL_MEMORY_LIMIT_MB="${SQLSERVER_MEMORY_MB:-2048}" --memory "${SQLSERVER_MEMORY_LIMIT:-3g}" \
    --mount "type=volume,source=$volume,target=/var/opt/mssql" \
    "mcr.microsoft.com/mssql/server:$SQLSERVER_IMAGE_TAG" >/dev/null
# Ready once it takes logins and the chosen databases have recovered (it takes logins first).
for _ in $(seq 180); do
    if [ "$(sql "$temp" "SELECT COUNT(*) FROM sys.databases WHERE name IN ($names) AND state_desc <> 'ONLINE'" 2>/dev/null)" = 0 ]; then
        summarize "$temp"
        exit 0
    fi
    sleep 1
done
echo "error: SQL Server didn't start on $volume within 3 minutes" >&2
exit 1
