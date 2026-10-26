#!/bin/bash
# Steps a DHIS2 instance through docker/dhis2/upgrade-path, one version at a time, from the one it's
# on (DHIS2_VERSION in its env) to --to (default: the last). For each version: fetches its WAR
# (dhis2-war), stops dhis2, runs that version's SQL against dhis2-db, sets DHIS2_VERSION and
# DHIS2_IMAGE_TAG in env, starts the instance, and waits for DHIS2 to come up, showing any migration
# errors in its log. Then asks before the next version. Run it again to carry on from where it stopped.
# Each step is logged to <instance dir>/dhis2-upgrade.log.
#
# Usage: openmrs-utils dhis2-upgrade --instance=<name> [--to=<version>] [--extra-sql-dir=<dir>]
#   --extra-sql-dir   <dir>/<version>/*.sql run after the built-in docker/dhis2/upgrade-sql files for
#                     that version: a site's own fixes, or known fixes from docker/dhis2/known-fixes
#   The instance must have been started once (dhis2-db exists). Take a backup first, and hold a
#   puppet-managed instance (/etc/puppet/build-disabled-<instance>), or puppet puts its version back.
#   DHIS2_UPGRADE_STEP_TIMEOUT  seconds to wait for each version to come up (default 7200)
#   DHIS2_UPGRADE_PATH, DHIS2_UPGRADE_SQL_DIR  replace the built-in path and SQL directory (tests)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
TOOL_DIR="$(cd "$UTILS_DIR/.." && pwd)"

INSTANCE=""
TO=""
EXTRA_SQL_DIR=""
for arg in "$@"; do
    case "$arg" in
        --instance=*) INSTANCE="${arg#*=}" ;;
        --to=*) TO="${arg#*=}" ;;
        --extra-sql-dir=*) EXTRA_SQL_DIR="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$INSTANCE" ] || usage
DIR="${OPENMRS_DOCKER_HOME:-$HOME/openmrs}/$INSTANCE"
[ -f "$DIR/env" ] || die "no instance found at $DIR"
[ -f "$DIR/dhis2-db.yaml" ] || die "$INSTANCE is not a DHIS2 instance (it has no dhis2-db service)"
[ -z "$EXTRA_SQL_DIR" ] || [ -d "$EXTRA_SQL_DIR" ] || die "no such directory: $EXTRA_SQL_DIR"
PATH_FILE="${DHIS2_UPGRADE_PATH:-$TOOL_DIR/docker/dhis2/upgrade-path}"
SQL_DIR="${DHIS2_UPGRADE_SQL_DIR:-$TOOL_DIR/docker/dhis2/upgrade-sql}"
LOG="$DIR/dhis2-upgrade.log"

VERSIONS=()
TAGS=()
while read -r v t _; do VERSIONS+=("$v"); TAGS+=("$t"); done < <(grep -v '^#' "$PATH_FILE" | awk 'NF')
index_of() { # <version>
    local i
    for i in "${!VERSIONS[@]}"; do [ "${VERSIONS[$i]}" != "$1" ] || { echo "$i"; return; }; done
    die "DHIS2 $1 isn't in $PATH_FILE"
}
env_value() { sed -n "s/^$1='\(.*\)'$/\1/p" "$DIR/env"; }

CURRENT=$(env_value DHIS2_VERSION)
FROM=$(index_of "$CURRENT")
LAST=$(index_of "${TO:-${VERSIONS[-1]}}")
if [ "$LAST" -le "$FROM" ]; then
    note "$INSTANCE is on DHIS2 $CURRENT: nothing to do."
    exit 0
fi
note "Upgrading $INSTANCE from DHIS2 $CURRENT to ${VERSIONS[$LAST]}, one version at a time."
note "If puppet manages it, hold it first (/etc/puppet/build-disabled-$INSTANCE), or puppet puts its version back."
docker inspect "$INSTANCE-dhis2-db" >/dev/null 2>&1 || die "$INSTANCE-dhis2-db doesn't exist: start $INSTANCE once first"

log_step() { # <to> <tag> <files> <seconds> <outcome>
    printf '%s %s -> %s %s sql=[%s] %ss %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CURRENT" "$@" >> "$LOG"
}
run_sql() { # <file>
    note "Running $1..."
    # shellcheck disable=SC2016 # expanded in the container
    docker exec -i "$INSTANCE-dhis2-db" sh -c \
        'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$1"
}
set_env() { # <name> <value>
    sed -i "s/^$1=.*/$1='$2'/" "$DIR/env"
}

for ((i = FROM + 1; i <= LAST; i++)); do
    v=${VERSIONS[$i]} tag=${TAGS[$i]} start=$(date +%s) files=()
    note ""
    note "=== DHIS2 $CURRENT -> $v (Tomcat $tag)"
    "$UTILS_DIR/dhis2-war.sh" --instance="$INSTANCE" --version="$v"
    docker start "$INSTANCE-dhis2-db" >/dev/null
    "$UTILS_DIR/wait-for-healthy.sh" --container="$INSTANCE-dhis2-db" --timeout=600
    docker stop "$INSTANCE-dhis2" >/dev/null 2>&1 || true
    for f in "$SQL_DIR/$v"/*.sql ${EXTRA_SQL_DIR:+"$EXTRA_SQL_DIR/$v"/*.sql}; do
        [ -f "$f" ] || continue
        files+=("$(basename "$f")")
        if ! run_sql "$f"; then
            log_step "$v" "$tag" "${files[*]}" $(($(date +%s) - start)) failed
            die "$f failed: DHIS2 is stopped and still on $CURRENT. Fix it (or add a fix with --extra-sql-dir), then run this again."
        fi
    done
    set_env DHIS2_VERSION "$v"
    set_env DHIS2_IMAGE_TAG "$tag"
    since=$(date +%s)
    "$TOOL_DIR/bin/openmrs-docker" "$INSTANCE" start
    if ! "$UTILS_DIR/wait-for-healthy.sh" --container="$INSTANCE-dhis2" \
            --timeout="${DHIS2_UPGRADE_STEP_TIMEOUT:-7200}" --fail-on-unhealthy=true; then
        log_step "$v" "$tag" "${files[*]}" $(($(date +%s) - start)) failed
        docker logs --since "$since" "$INSTANCE-dhis2" 2>&1 | grep -i -E 'flyway|migration' | tail -20 >&2 || true
        die "DHIS2 $v didn't come up. Its env now says $v: fix the cause and run this again to retry $v, or see docs/dhis2-upgrade.md."
    fi
    errors=$(docker logs --since "$since" "$INSTANCE-dhis2" 2>&1 | grep -i -E 'flyway.*(error|fail)|migration.*fail' || true)
    [ -z "$errors" ] || { note "Migration errors in DHIS2 $v's log:"; note "$errors"; }
    log_step "$v" "$tag" "${files[*]}" $(($(date +%s) - start)) ok
    note "DHIS2 $v is up ($(($(date +%s) - start))s)."
    CURRENT=$v
    if [ "$i" -lt "$LAST" ]; then
        printf 'Continue to %s? [y/N] ' "${VERSIONS[$((i + 1))]}" >&2
        read -r answer || answer=""
        [ "$answer" = y ] || { note "Stopped on DHIS2 $v. Run this again to carry on."; exit 0; }
    fi
done
note "$INSTANCE is on DHIS2 $CURRENT."
