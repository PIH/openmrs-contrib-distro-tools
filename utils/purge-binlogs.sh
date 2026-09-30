#!/bin/bash
# General-purpose: has a MySQL or MariaDB server delete all of its binary logs except the one it's
# currently writing (a few hundred bytes once this runs), using the server's own PURGE BINARY LOGS
# rather than touching files. Run it before turning binary logging off -- once it's off, the server
# can't purge them any more. Usage:
#   utils/purge-binlogs.sh (--container=<name> | --host=<host> [--port=3306]) [--user=root]
#       [--client-image=mysql:5.6]
#
# --container runs the client inside a running MySQL/MariaDB container (`docker exec`). --host
# instead connects over TCP -- e.g. --host=127.0.0.1 for a MySQL installed directly on the host --
# using the client from --client-image, run with host networking.
#
# MYSQL_PASSWORD (env var) authenticates as --user; defaults to "openmrs" if unset. --user needs the
# SUPER (or BINLOG_ADMIN) privilege, so root by default. The password is passed to `docker` as a
# bare `-e MYSQL_PWD` and read from there by the client, so it's on no command line.
set -euo pipefail

CONTAINER=
DB_HOST=
DB_PORT=3306
CLIENT_IMAGE=mysql:5.6
DB_USER=root
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --host=*) DB_HOST="${arg#*=}" ;;
        --port=*) DB_PORT="${arg#*=}" ;;
        --client-image=*) CLIENT_IMAGE="${arg#*=}" ;;
        --user=*) DB_USER="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
usage() { echo "usage: $0 (--container=<name> | --host=<host> [--port=3306]) [--user=root] [--client-image=mysql:5.6]" >&2; exit 1; }
[ -z "$CONTAINER" ] && [ -z "$DB_HOST" ] && usage
[ -n "$CONTAINER" ] && [ -n "$DB_HOST" ] && { echo "error: pass either --container or --host, not both" >&2; exit 1; }

# MariaDB 11+ images have only the `mariadb` client, no `mysql`.
if [ -n "$CONTAINER" ]; then
    CLIENT=mysql
    docker exec "$CONTAINER" sh -c 'command -v mysql' >/dev/null 2>&1 || CLIENT=mariadb
    SQL_CMD=(docker exec -i -e MYSQL_PWD "$CONTAINER" "$CLIENT" "-u$DB_USER" -N)
else
    SQL_CMD=(docker run -i --rm --network host -e MYSQL_PWD "$CLIENT_IMAGE" mysql "-h$DB_HOST" "-P$DB_PORT" "-u$DB_USER" -N)
fi
sql() { MYSQL_PWD="${MYSQL_PASSWORD:-openmrs}" "${SQL_CMD[@]}" -e "$1"; }

SOURCE="${CONTAINER:-$DB_HOST:$DB_PORT}"
[ "$(sql 'SELECT @@log_bin')" = 1 ] || {
    echo "error: binary logging is off on $SOURCE, so the server can't purge its binlogs. Turn it back on (e.g. OPENMRS_DB_OPT_log_bin=mysql-bin), restart, then run this again." >&2
    exit 1
}
summary() { sql 'SHOW BINARY LOGS' | awk '{ n++; b += $2 } END { printf "%d file(s), %d bytes", n, b }'; }

echo "Binary logs on $SOURCE before: $(summary)" >&2
# FLUSH starts a new, empty binlog; PURGE ... TO then deletes every binlog before it. The newest
# file listed by SHOW BINARY LOGS is the current one (SHOW MASTER STATUS was removed in MySQL 8.4).
sql 'FLUSH BINARY LOGS'
CURRENT=$(sql 'SHOW BINARY LOGS' | awk 'END { print $1 }')
sql "PURGE BINARY LOGS TO '$CURRENT'"
echo "Binary logs on $SOURCE after:  $(summary)" >&2
