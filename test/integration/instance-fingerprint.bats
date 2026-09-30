#!/usr/bin/env bats
# openmrs-docker <name> fingerprint reads a stopped instance's volumes with the instance's own
# image and server options, so it matches a fingerprint of the running instance.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    write_tiny_dump dump.sql
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

@test "matches a fingerprint of the running instance, [server] included" {
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_success
    run "$BIN/openmrs-docker" "$NAME" fingerprint --output=stopped.txt
    assert_success
    run cat stopped.txt
    # the instance's OPENMRS_DB_OPT_character_set_server, not the image's default (latin1 on 5.6)
    assert_line 'character_set_server utf8'
    assert_line 'openmrs.marker 1'
    # a plain --db-volume fingerprint reads the image's defaults instead
    run "$UTILS/fingerprint.sh" --db-volume="${NAME}_db-data"
    assert_line 'character_set_server latin1'
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    wait_for_mysql "$NAME-openmrs-db" root openmrs
    MYSQL_ROOT_PASSWORD=openmrs "$UTILS/fingerprint.sh" --container="$NAME-openmrs-db" --output=running.txt
    run diff stopped.txt running.txt
    assert_success
}

@test "--data-dir adds the instance's openmrs-data volume" {
    # with the openmrs service too, which declares openmrs-data (initialize never starts it)
    destroy_instance "$NAME"
    create_instance "$NAME"
    make_data_fixture "$BATS_TEST_TMPDIR/data"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH="$BATS_TEST_TMPDIR/data"
    assert_success
    run "$BIN/openmrs-docker" "$NAME" fingerprint --data-dir --exclude-distribution-artifacts
    assert_success
    assert_line 'complex_obs/ files=1 bytes=4'
    refute_output --partial 'modules/'
}

@test "refuses while the instance is running" {
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" fingerprint
    assert_failure
    assert_output --partial "${NAME}_db-data is in use by a running container"
}
