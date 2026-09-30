# Reaching a MySQL/MariaDB server, for the utils/ scripts. Sourced after common.sh.
#
# A script takes the server as one of:
#   --container=<name>         a running MySQL/MariaDB container; the tools run inside it
#   --host=<host> [--port=3306]
#                              a server reached over TCP (e.g. 127.0.0.1 for a MySQL installed on
#                              the host); the tools run in DB_CLIENT_IMAGE (a script's
#                              --client-image) with host networking, so the host needs only Docker
# The password reaches the tools as MYSQL_PWD, which docker passes by name.
# shellcheck disable=SC2034 # the scripts use these

DB_CONTAINER=
DB_HOST=
DB_PORT=3306
DB_CLIENT_IMAGE=mysql:5.6
DB_USER=root

# Takes <arg> if it's one of the options above; returns 1 if not.
mysql_source_arg() {
    case "$1" in
        --container=*) DB_CONTAINER="${1#*=}" ;;
        --host=*) DB_HOST="${1#*=}" ;;
        --port=*) DB_PORT="${1#*=}" ;;
        *) return 1 ;;
    esac
}

# True if --container or --host was given; refuses both. Sets MYSQL_SOURCE, which names the server
# in messages.
mysql_source_given() {
    [ -z "$DB_CONTAINER" ] || [ -z "$DB_HOST" ] || die "pass either --container or --host, not both"
    MYSQL_SOURCE=${DB_CONTAINER:-$DB_HOST:$DB_PORT}
    [ -n "$DB_CONTAINER$DB_HOST" ]
}

# Logs in as DB_USER with <password> from here on, and finds the tools the server's image (or
# DB_CLIENT_IMAGE) has: MariaDB 11+ has only mariadb and mariadb-dump.
mysql_connect() { # <password>
    export MYSQL_PWD=$1
    local probe='command -v mysql >/dev/null && echo mysql || echo mariadb
                 command -v mysqldump >/dev/null && echo mysqldump || echo mariadb-dump' tools
    if [ -n "$DB_CONTAINER" ]; then
        tools=$(docker exec "$DB_CONTAINER" sh -c "$probe") || die "can't reach container $DB_CONTAINER"
    else
        tools=$(docker run --rm --entrypoint sh "$DB_CLIENT_IMAGE" -c "$probe") || die "can't run $DB_CLIENT_IMAGE"
    fi
    { read -r MYSQL_CLIENT; read -r MYSQL_DUMP; } <<< "$tools"
}

_mysql_run() { # <tool> [args...], with stdin
    local tool=$1; shift
    if [ -n "$DB_CONTAINER" ]; then
        docker exec -i -e MYSQL_PWD "$DB_CONTAINER" "$tool" "-u$DB_USER" "$@"
    else
        docker run -i --rm --network host -e MYSQL_PWD "$DB_CLIENT_IMAGE" \
            "$tool" "-h$DB_HOST" "-P$DB_PORT" "-u$DB_USER" "$@"
    fi
}

# Runs <query>, printing its rows tab-separated without a header.
sql() { _mysql_run "$MYSQL_CLIENT" -N -B <<< "$1"; }

# Runs mysqldump with [args...], to stdout.
mysql_dump() { _mysql_run "$MYSQL_DUMP" "$@" < /dev/null; }

# Removes DEFINER=`user`@`host` clauses from SQL on stdin; mysqldump has no option to leave them out.
strip_definers() { sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g'; }
