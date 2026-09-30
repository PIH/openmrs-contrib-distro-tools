#!/usr/bin/env bats
# backup-percona -> convert-percona-backup -> initialize RESTORE_MYSQL_DATA_PATH round trips.
#
# A physical backup carries the source's own accounts; initialize sets them to the instance's
# passwords (utils/reset-mysql-accounts.sh). The source gets accounts like a legacy server's: an
# openmrs@localhost with its own password, an anonymous account, and an unrelated petl account.

load ../helpers

setup_file() {
    # One test changes the source's root password for a moment, which would break a backup another
    # test took at the same time.
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true
    export SRC_DB="$(file_res src)"
    start_source_db "$SRC_DB"
    mysql_exec "$SRC_DB" openmrs "
        CREATE USER 'openmrs'@'localhost' IDENTIFIED BY 'legacy-openmrs-pw';
        GRANT ALL PRIVILEGES ON openmrs.* TO 'openmrs'@'localhost';
        CREATE USER ''@'localhost';
        CREATE USER 'petl'@'localhost' IDENTIFIED BY 'petl-pw';"
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

@test "a physical restore's accounts get the instance's passwords; the source's other accounts are kept and listed" {
    percona_backup backup >/dev/null 2>&1
    local datadir
    datadir=$("$UTILS/convert-percona-backup.sh" --backup-dir=backup --output-dir="$BATS_TEST_TMPDIR/datadir" 2>/dev/null)
    NAME="$(instance)"
    OPENMRS_DB_PASSWORD=instance-pw OPENMRS_DB_ROOT_PASSWORD=instance-root SERVICES=openmrs-db create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DATA_PATH="$datadir"
    assert_success
    assert_output --partial "Set the password of openmrs@localhost"
    assert_output --partial "Set the password of root@%"
    assert_output --partial "Removed anonymous account ''@localhost"
    assert_output --partial "Kept the other accounts (remove any this instance doesn't need): petl@localhost"
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    wait_for_mysql "$NAME-openmrs-db" root instance-root
    # locally (the healthcheck's login, which the legacy openmrs@localhost would otherwise take) ...
    run docker exec "$NAME-openmrs-db" sh -c 'mysql -h127.0.0.1 -uopenmrs -pinstance-pw -N -e "SELECT id FROM openmrs.marker" 2>/dev/null'
    assert_output 1
    # ... and from another container, as the openmrs container connects
    run docker run --rm --network "${NAME}_default" "$MYSQL_IMAGE" \
        sh -c 'mysql -hopenmrs-db -uopenmrs -pinstance-pw -N -e "SELECT id FROM openmrs.marker" 2>/dev/null'
    assert_output 1
}

@test "MYSQL_ROOT_PASSWORD never appears in a docker command line" {
    mysql_exec "$SRC_DB" openmrs "SET PASSWORD FOR 'root'@'%' = PASSWORD('s3cret-root-pw');"
    record_docker_argv
    MYSQL_ROOT_PASSWORD=s3cret-root-pw run "$UTILS/backup-percona.sh" --container="$SRC_DB" --volume="$SRC_DB-data" --output=backup
    local status_before_restore=$status
    assert_not_in_docker_argv s3cret-root-pw
    # nor inside the containers, for a .7z (innobackupex and 7z both run there)
    MYSQL_ROOT_PASSWORD=s3cret-root-pw ARCHIVE_PASSWORD=s3cret-ps-root assert_not_in_ps_while s3cret-root-pw \
        "$UTILS/backup-percona.sh" --container="$SRC_DB" --volume="$SRC_DB-data" --output=backup-ps.7z
    # Checked first: restoring the password below goes through a command line itself.
    mysql_exec "$SRC_DB" s3cret-root-pw "SET PASSWORD FOR 'root'@'%' = PASSWORD('openmrs');"
    assert_equal "$status_before_restore" 0
}
