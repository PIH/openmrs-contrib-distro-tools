#!/bin/bash
# Summarizes a MySQL/MariaDB server's databases (and optionally an OpenMRS data directory), to
# compare a source with its restored copy: fingerprint both and `diff` them. No row contents,
# passwords or other secrets are written.
#
# Usage: openmrs-utils fingerprint (--container=<name> | --host=<host> [--port=3306]
#            [--client-image=mysql:5.6] [--user=root] | --db-volume=<volume or dir> [--image=mysql:5.6]
#            [--server-opt=<flag>...]) [--database=openmrs]
#            [--data-dir=<volume or dir> [--exclude-distribution-artifacts]] [--output=<file>]
#   --db-volume   a stopped server's data directory, read by starting --image on it with grants
#                 and networking off. Give the instance's image and server options, or [server]
#                 shows the image's defaults: `openmrs-docker <name> fingerprint` does both.
#   --database    the OpenMRS database, for [recent]
#   --data-dir    also summarizes this OpenMRS data directory; --exclude-distribution-artifacts
#                 leaves out what the image supplies, as backup-openmrs-data-directory does
#   MYSQL_PASSWORD  password for --user, for --container and --host (required)
#
# Sections, each sorted, one fact per line, so a diff shows only what changed:
#   [server]     version, character set and collation, lower_case_table_names, sql_mode,
#                time_zone, and how many time zones are loaded
#   [databases]  each non-system database and its number of tables
#   [rows]       every table's exact row count (COUNT(*), so minutes on a large obs)
#   [objects]    routines, triggers and views, by name
#   [recent]     the highest id and date_created in --database's encounter, obs, patient, person
#                and users: a backup taken before the last writes shows here
#   [accounts]   user@host
#   [data-dir]   files and bytes per top-level folder (top-level files together)
#
# Expected differences between a source and its restore: [accounts] (initialize resets them after
# a physical restore), databases a physical restore brought along, [server] if the servers are
# configured differently, and once OpenMRS has started, its Liquibase and scheduler tables -- so
# fingerprint a restore before its first start.
set -euo pipefail
# One sort order whoever runs it, or two fingerprints taken under different locales differ in order.
export LC_ALL=C
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/mysql.sh
. "$UTILS_DIR/lib/mysql.sh"

DB_VOLUME=
IMAGE=mysql:5.6
SERVER_OPTS=()
DATABASE=openmrs
DATA_DIR=
EXCLUDE_DISTRIBUTION_ARTIFACTS=false
OUTPUT=
for arg in "$@"; do
    case "$arg" in
        --client-image=*) DB_CLIENT_IMAGE="${arg#*=}" ;;
        --user=*) DB_USER="${arg#*=}" ;;
        --db-volume=*) DB_VOLUME="${arg#*=}" ;;
        --image=*) IMAGE="${arg#*=}" ;;
        --server-opt=*) SERVER_OPTS+=("${arg#*=}") ;;
        --database=*) DATABASE="${arg#*=}" ;;
        --data-dir=*) DATA_DIR="${arg#*=}" ;;
        --exclude-distribution-artifacts) EXCLUDE_DISTRIBUTION_ARTIFACTS=true ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        *) mysql_source_arg "$arg" || die "unknown argument: $arg" ;;
    esac
done

if [ -z "$DB_VOLUME" ]; then
    mysql_source_given || usage
    mysql_password
    mysql_connect "$DB_PASSWORD"
else
    [ -z "$DB_CONTAINER$DB_HOST" ] || usage
    refuse_if_in_use "$DB_VOLUME" "two servers on one data directory corrupt it"
    DB_CONTAINER="fingerprint-$(date +%Y%m%d%H%M%S)-$$"
    on_exit 'docker stop -t 60 "$DB_CONTAINER" >/dev/null 2>&1; docker rm -f "$DB_CONTAINER" >/dev/null 2>&1'
    # The image's entrypoint leaves an existing data directory alone and passes the flags on.
    docker run -d --name "$DB_CONTAINER" -v "$DB_VOLUME:/var/lib/mysql" "$IMAGE" \
        ${SERVER_OPTS[@]+"${SERVER_OPTS[@]}"} --skip-grant-tables --skip-networking >/dev/null
    # A large data directory can spend a long time in crash recovery first.
    until docker exec "$DB_CONTAINER" sh -c 'mysqladmin -uroot ping || mariadb-admin -uroot ping' >/dev/null 2>&1; do
        [ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER")" = true ] ||
            { docker logs --tail 20 "$DB_CONTAINER" >&2; die "MySQL didn't start on $DB_VOLUME"; }
        sleep 1
    done
    mysql_connect ""
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
        docker run --rm -e LEAVE_OUT="$leave_out" -v "$DATA_DIR:/d:ro" "$ALPINE_IMAGE" sh -c '
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
    note "Wrote $OUTPUT."
else
    fingerprint
fi
