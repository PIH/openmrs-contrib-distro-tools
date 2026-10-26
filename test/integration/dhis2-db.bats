#!/usr/bin/env bats
# dhis2-db: PostGIS for a DHIS2 instance, with server options from DHIS2_DB_OPT_* in env.

load ../helpers

teardown() {
    destroy_instance "$(instance)"
    common_teardown
}

@test "dhis2-db starts healthy with the server options from env" {
    NAME="$(instance)"
    SERVICES=dhis2-db create_instance "$NAME"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
    run "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2-db" --timeout=120
    assert_success
    run docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc 'SHOW max_locks_per_transaction'
    assert_output 96
    run docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc 'SELECT postgis_version()'
    assert_success
}
