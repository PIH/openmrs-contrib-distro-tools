#!/usr/bin/env bats
# backup-percona -> convert-percona-backup -> initialize RESTORE_MYSQL_DATA_PATH round trips.
#
# The source's credentials match openmrs-docker's defaults: a physical backup carries the source's
# own user accounts, so that's what lets the restored instance log in (see the README caveat).

load ../helpers

setup_file() {
    export SRC_DB="$RUN_PREFIX-f-perconasrc"
    start_source_db "$SRC_DB"
}
teardown_file() { common_teardown_file; }

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

percona_backup() { # <output dir> [args...]
    MYSQL_ROOT_PASSWORD=openmrs "$UTILS/backup-percona.sh" --container="$SRC_DB" --volume="$SRC_DB-data" --output="$@"
}

# Backs up, converts and initializes a new instance from the result.
restore_physical() { # [backup-percona args...]
    percona_backup backup "$@" >/dev/null 2>&1
    local datadir
    datadir=$("$UTILS/convert-percona-backup.sh" --backup-dir=backup --output-dir="$BATS_TEST_TMPDIR/datadir" 2>/dev/null)
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DATA_PATH="$datadir"
}

@test "a full physical backup restores through initialize" {
    restore_physical
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "a physical backup limited with --databases restores through initialize" {
    restore_physical --databases=openmrs
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "a physical restore whose credentials don't match fails within INITIALIZE_DB_TIMEOUT, saying why" {
    percona_backup backup >/dev/null 2>&1
    local datadir
    datadir=$("$UTILS/convert-percona-backup.sh" --backup-dir=backup --output-dir="$BATS_TEST_TMPDIR/datadir" 2>/dev/null)
    NAME="$(instance)"
    OPENMRS_DB_PASSWORD=not-the-source-password create_instance "$NAME"
    SECONDS=0
    run_initialize "$NAME" RESTORE_MYSQL_DATA_PATH="$datadir" INITIALIZE_DB_TIMEOUT=60
    assert_failure
    assert_output --partial 'credentials'
    assert [ "$SECONDS" -lt 150 ]
}

@test "MYSQL_ROOT_PASSWORD never appears in a docker command line" {
    mysql_exec "$SRC_DB" openmrs "SET PASSWORD FOR 'root'@'%' = PASSWORD('s3cret-root-pw');"
    record_docker_argv
    MYSQL_ROOT_PASSWORD=s3cret-root-pw run "$UTILS/backup-percona.sh" --container="$SRC_DB" --volume="$SRC_DB-data" --output=backup
    local status_before_restore=$status
    assert_not_in_docker_argv s3cret-root-pw
    # Checked first: restoring the password below goes through a command line itself.
    mysql_exec "$SRC_DB" s3cret-root-pw "SET PASSWORD FOR 'root'@'%' = PASSWORD('openmrs');"
    assert_equal "$status_before_restore" 0
}
