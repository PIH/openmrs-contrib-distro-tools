#!/bin/bash
# General-purpose: writes a summary of a MySQL server's databases (and optionally an OpenMRS data
# directory) to compare before and after a backup and restore: take one of the source, one of the
# restored copy, and `diff` them. Usage:
#   utils/fingerprint.sh (--container=<name> | --host=<host> [--port=3306] [--client-image=mysql:5.6]
#       | --db-volume=<db data volume or host dir> [--image=mysql:5.6])
#       [--database=openmrs] [--data-dir=<volume or dir> [--exclude-distribution-artifacts]]
#       [--output=<file>]
#
# --container reads a running MySQL/MariaDB container (`docker exec`). --host connects over TCP with
# host networking, e.g. --host=127.0.0.1 for a MySQL installed on a legacy host, using the client
# from --client-image. Both log in as root with MYSQL_ROOT_PASSWORD (env var, a secret; passed to
# `docker` by name only, so it never appears in argv). --db-volume reads a *stopped* instance's
# data directory: it starts --image's server on it with --skip-grant-tables --skip-networking (no
# password needed, nothing can connect), and stops it cleanly afterwards. It refuses while a
# container is using the volume. Use the image the instance runs.
#
# Sections, each sorted, one fact per line, so a diff shows only what changed:
#   [server]    version (and vendor), character set and collation, lower_case_table_names, sql_mode, time_zone,
#               how many time zones are loaded
#   [databases] each non-system database and its number of tables
#   [rows]      every table's exact row count (COUNT(*), so this can take minutes on a large obs)
#   [objects]   routines, triggers and views, by name
#   [recent]    the highest id and date_created on --database's encounter, obs, patient, person and
#               users tables -- a backup taken before the last writes shows here
#   [accounts]  user@host
#   [data-dir]  with --data-dir: files and bytes per top-level folder (top-level files together).
#               --exclude-distribution-artifacts leaves out the contents of modules/, owa/,
#               configuration/ and frontend/ and .openmrs-lib-cache, like backup-openmrs-data-directory
#               (the image supplies them, so they differ legitimately).
# No row contents, passwords or other secrets are written.
#
# Expected differences between a source and its restore: [accounts] (initialize resets them after
# a physical restore; a logical one has only the instance's), databases a physical restore brought
# along, [server] settings if the two servers are configured differently, and, once OpenMRS has
# started, Liquibase/scheduler tables -- so fingerprint a restore before its first start.
set -euo pipefail

CONTAINER=
DB_HOST=
DB_PORT=3306
CLIENT_IMAGE=mysql:5.6
DB_VOLUME=
IMAGE=mysql:5.6
DATABASE=openmrs
DATA_DIR=
EXCLUDE_DISTRIBUTION_ARTIFACTS=false
OUTPUT=
for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#*=}" ;;
        --host=*) DB_HOST="${arg#*=}" ;;
        --port=*) DB_PORT="${arg#*=}" ;;
        --client-image=*) CLIENT_IMAGE="${arg#*=}" ;;
        --db-volume=*) DB_VOLUME="${arg#*=}" ;;
        --image=*) IMAGE="${arg#*=}" ;;
        --database=*) DATABASE="${arg#*=}" ;;
        --data-dir=*) DATA_DIR="${arg#*=}" ;;
        --exclude-distribution-artifacts) EXCLUDE_DISTRIBUTION_ARTIFACTS=true ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
usage() {
    echo "usage: $0 (--container=<name> | --host=<host> [--port=3306] | --db-volume=<volume or dir> [--image=mysql:5.6]) [--database=openmrs] [--data-dir=<volume or dir> [--exclude-distribution-artifacts]] [--output=<file>]" >&2
    exit 1
}
SOURCES=0
for v in "$CONTAINER" "$DB_HOST" "$DB_VOLUME"; do [ -n "$v" ] && SOURCES=$((SOURCES + 1)); done
[ "$SOURCES" -eq 1 ] || usage

# sql <query>: tab-separated rows, no header.
if [ -n "$CONTAINER" ]; then
    CLIENT=mysql
    docker exec "$CONTAINER" sh -c 'command -v mysql' >/dev/null 2>&1 || CLIENT=mariadb
    MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-openmrs}"; export MYSQL_PWD
    sql() { docker exec -i -e MYSQL_PWD "$CONTAINER" "$CLIENT" -uroot -N -B <<< "$1"; }
elif [ -n "$DB_HOST" ]; then
    MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-openmrs}"; export MYSQL_PWD
    sql() { docker run -i --rm --network host -e MYSQL_PWD "$CLIENT_IMAGE" mysql "-h$DB_HOST" "-P$DB_PORT" -uroot -N -B <<< "$1"; }
else
    if [ -n "$(docker ps -q --filter "volume=$DB_VOLUME")" ]; then
        echo "error: a running container is using $DB_VOLUME -- stop it first (two servers on one data directory corrupt it)" >&2
        exit 1
    fi
    TMP_DB="fingerprint-$(date +%Y%m%d%H%M%S)-$$"
    trap 'docker stop -t 60 "$TMP_DB" >/dev/null 2>&1; docker rm -f "$TMP_DB" >/dev/null 2>&1 || true' EXIT
    # The image's entrypoint leaves an existing data directory alone and passes the flags on.
    docker run -d --name "$TMP_DB" -v "$DB_VOLUME:/var/lib/mysql" "$IMAGE" --skip-grant-tables --skip-networking >/dev/null
    CLIENT=mysql
    docker exec "$TMP_DB" sh -c 'command -v mysql' >/dev/null 2>&1 || CLIENT=mariadb
    # A large data directory can spend a long time in crash recovery first.
    until docker exec "$TMP_DB" "$CLIENT" -uroot -e 'SELECT 1' >/dev/null 2>&1; do
        [ "$(docker inspect -f '{{.State.Running}}' "$TMP_DB")" = true ] || { docker logs --tail 20 "$TMP_DB" >&2; echo "error: MySQL didn't start on $DB_VOLUME" >&2; exit 1; }
        sleep 1
    done
    sql() { docker exec -i "$TMP_DB" "$CLIENT" -uroot -N -B <<< "$1"; }
fi

SYSTEM_DBS="'mysql', 'information_schema', 'performance_schema', 'sys'"
ident() { printf '`%s`' "${1//\`/\`\`}"; }   # a quoted SQL identifier

fingerprint() {
    echo "[server]"
    # The version number only: VERSION() also says e.g. "-log" when binary logging is on.
    sql "SELECT CONCAT('version ', SUBSTRING_INDEX(VERSION(), '-', 1)), CONCAT('version_comment ', @@version_comment),
            CONCAT('character_set_server ', @@character_set_server),
            CONCAT('collation_server ', @@collation_server), CONCAT('lower_case_table_names ', @@lower_case_table_names),
            CONCAT('sql_mode ', @@sql_mode), CONCAT('time_zone ', @@time_zone),
            CONCAT('time_zones_loaded ', (SELECT COUNT(*) FROM mysql.time_zone_name))" | tr '\t' '\n'

    echo "[databases]"
    sql "SELECT CONCAT(s.schema_name, ' tables=', COUNT(t.table_name)) FROM information_schema.schemata s
            LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name AND t.table_type = 'BASE TABLE'
            WHERE s.schema_name NOT IN ($SYSTEM_DBS) GROUP BY s.schema_name" | sort

    echo "[rows]"
    local counts="" db table
    while IFS=$'\t' read -r db table; do
        [ -n "$db" ] || continue
        counts+="${counts:+ UNION ALL }SELECT CONCAT('$db.$table ', COUNT(*)) FROM $(ident "$db").$(ident "$table")"
    done < <(sql "SELECT table_schema, table_name FROM information_schema.tables
                  WHERE table_schema NOT IN ($SYSTEM_DBS) AND table_type = 'BASE TABLE'")
    [ -z "$counts" ] || sql "$counts" | sort

    echo "[objects]"
    { sql "SELECT CONCAT(routine_schema, ' ', LOWER(routine_type), ' ', routine_name) FROM information_schema.routines
               WHERE routine_schema NOT IN ($SYSTEM_DBS)"
      sql "SELECT CONCAT(trigger_schema, ' trigger ', trigger_name) FROM information_schema.triggers
               WHERE trigger_schema NOT IN ($SYSTEM_DBS)"
      sql "SELECT CONCAT(table_schema, ' view ', table_name) FROM information_schema.views
               WHERE table_schema NOT IN ($SYSTEM_DBS)"; } | sort

    echo "[recent]"
    local spec tbl id_col has_date
    for spec in encounter:encounter_id obs:obs_id patient:patient_id person:person_id users:user_id; do
        tbl=${spec%%:*} id_col=${spec#*:}
        [ -n "$(sql "SELECT 1 FROM information_schema.tables WHERE table_schema = '$DATABASE' AND table_name = '$tbl'")" ] || continue
        has_date=$(sql "SELECT 1 FROM information_schema.columns WHERE table_schema = '$DATABASE' AND table_name = '$tbl' AND column_name = 'date_created'")
        if [ -n "$has_date" ]; then
            sql "SELECT CONCAT('$DATABASE.$tbl max_$id_col=', IFNULL(MAX($id_col), 'none'), ' max_date_created=', IFNULL(MAX(date_created), 'none'))
                 FROM $(ident "$DATABASE").$(ident "$tbl")"
        else
            sql "SELECT CONCAT('$DATABASE.$tbl max_$id_col=', IFNULL(MAX($id_col), 'none')) FROM $(ident "$DATABASE").$(ident "$tbl")"
        fi
    done

    echo "[accounts]"
    sql "SELECT CONCAT(user, '@', host) FROM mysql.user" | sort

    if [ -n "$DATA_DIR" ]; then
        echo "[data-dir]"
        local leave_out=""
        $EXCLUDE_DISTRIBUTION_ARTIFACTS && leave_out="modules owa configuration frontend .openmrs-lib-cache"
        # busybox: file count and bytes per top-level folder; files at the top level together.
        docker run --rm -e LEAVE_OUT="$leave_out" -v "$DATA_DIR:/d:ro" alpine:3.21 sh -c '
            summarize() { find "$1" -type f $2 -exec stat -c %s {} + 2>/dev/null | awk -v n="$3" "{ c++; b += \$1 } END { printf \"%s files=%d bytes=%.0f\n\", n, c, b }"; }
            for e in /d/* /d/.[!.]*; do
                [ -e "$e" ] || continue
                name=${e#/d/}
                case " $LEAVE_OUT " in *" $name "*) continue ;; esac
                [ -d "$e" ] && summarize "$e" "" "$name/"
            done
            summarize /d "-maxdepth 1" "(top level)"' | sort
    fi
}

if [ -n "$OUTPUT" ]; then
    fingerprint > "$OUTPUT"
    echo "Wrote $OUTPUT." >&2
else
    fingerprint
fi
