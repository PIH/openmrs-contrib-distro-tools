#!/usr/bin/env bats
# A real initialize holds the instance lock for its whole run, so puppet's `start` can't interleave.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

@test "start refuses while initialize runs, and works once it's done" {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    write_tiny_dump dump.sql
    RESTORE_MYSQL_DUMP_PATH=dump.sql timeout 300 "$BIN/openmrs-docker" "$NAME" initialize > init.log 2>&1 3>&- &
    local init=$!
    until grep -q 'Waiting for' init.log; do
        kill -0 "$init" 2>/dev/null || { cat init.log; fail "initialize ended early"; }
        sleep 0.2
    done
    run "$BIN/openmrs-docker" "$NAME" start
    assert_failure
    assert_output --partial "$NAME is busy: initialize (pid"
    wait "$init"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_success
}
