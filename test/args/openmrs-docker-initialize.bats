#!/usr/bin/env bats
# openmrs-docker initialize validates its restore sources before starting anything, and never runs
# against an instance that already has data.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    create_instance "$NAME"
    write_tiny_dump dump.sql
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

@test "refuses to run when a data volume already exists, leaving it untouched" {
    docker volume create "${NAME}_db-data" >/dev/null
    docker run --rm -v "${NAME}_db-data:/v" alpine:3.21 touch /v/existing
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_failure
    assert_output --partial "${NAME}_db-data already exists"
    run tree_of_volume "${NAME}_db-data"
    assert_output ./existing
}

@test "requires a database source" {
    run_initialize "$NAME" SEED_IMAGE_NAME=
    assert_failure
    assert_output --partial 'set exactly one of RESTORE_MYSQL_DUMP_PATH, RESTORE_MYSQL_DATA_PATH, or SEED_IMAGE_NAME'
    assert_no_leftovers
}

@test "rejects two database sources at once" {
    mkdir datadir
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_MYSQL_DATA_PATH=datadir
    assert_failure
    assert_output --partial 'set exactly one of'
    assert_no_leftovers
}

@test "rejects a RESTORE_MYSQL_DUMP_PATH that doesn't exist" {
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=nope.sql
    assert_failure
    assert_output --partial 'no such file: nope.sql'
    assert_no_leftovers
}

@test "rejects a RESTORE_MYSQL_DATA_PATH that doesn't exist" {
    run_initialize "$NAME" RESTORE_MYSQL_DATA_PATH=nope
    assert_failure
    assert_output --partial 'no such directory: nope'
    assert_no_leftovers
}

@test "rejects a RESTORE_OPENMRS_DATA_PATH that doesn't exist" {
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH=nope.tar.gz
    assert_failure
    assert_output --partial 'no such file or directory: nope.tar.gz'
    assert_no_leftovers
}

@test "rejects a RESTORE_OPENMRS_DATA_PATH file that isn't a supported archive" {
    touch data.rar
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH=data.rar
    assert_failure
    assert_output --partial 'must be a directory or a .tar.gz/.tgz/.tar/.7z/.zip archive'
    assert_no_leftovers
}
