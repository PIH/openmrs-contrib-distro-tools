#!/usr/bin/env bats
# Commands that change an instance hold its lock, and refuse while another command holds it: puppet
# runs `pull && start` on every apply, which mustn't happen part way through e.g. an initialize.

load ../helpers

setup() {
    NAME="$(instance)"
    create_instance "$NAME" --services=openmrs-db
    LOCK="$PIHX_HOME/$NAME/.lock"
}
teardown() {
    [ -z "${HOLDER:-}" ] || kill "$HOLDER" 2>/dev/null || true
    remove_test_instance "$NAME"
    common_teardown
}

# Holds the lock from another process, the way a running command would.
hold_lock() {
    ( exec 9>>"$LOCK"; flock 9; echo "initialize (pid $BASHPID, started now)" > "$LOCK"; exec sleep 60 ) 3>&- &
    HOLDER=$!
    until grep -q initialize "$LOCK" 2>/dev/null; do sleep 0.1; done
}

@test "a changing command refuses while another holds the lock, naming the holder" {
    hold_lock
    for cmd in start stop restart update pull 'openmrs-db reset-accounts' destroy archive; do
        # shellcheck disable=SC2086 # a command and its arguments
        run "$BIN/openmrs-docker" "$NAME" $cmd
        assert_failure
        assert_output --partial "$NAME is busy: initialize (pid"
    done
    run "$BIN/openmrs-docker" "$NAME" add-service openmrs
    assert_failure
    assert_output --partial "is busy"
    [ -d "$PIHX_HOME/$NAME" ]
}

@test "run-service refuses while the lock is held, but doesn't hold it itself" {
    printf 'services:\n  job:\n    image: alpine:3.21\n    profiles: ["job"]\n' \
        > "$PIHX_HOME/$NAME/openmrs-db.override.yaml"
    hold_lock
    run "$BIN/openmrs-docker" "$NAME" run-service job true
    assert_failure
    assert_output --partial "is busy"
}

@test "status works while the lock is held, and shows the holder" {
    hold_lock
    run "$BIN/openmrs-docker" "$NAME" status
    assert_success
    assert_output --partial "Busy: initialize (pid"
}

@test "the lock is released when its holder exits, however it exits" {
    hold_lock
    kill -9 "$HOLDER"; wait "$HOLDER" 2>/dev/null || true; HOLDER=
    run "$BIN/openmrs-docker" "$NAME" stop
    assert_success
    run "$BIN/openmrs-docker" "$NAME" status
    refute_output --partial "Busy:"
    # a failed command releases it too
    run_initialize "$NAME" --from "$(from_folder)"
    assert_failure
    run "$BIN/openmrs-docker" "$NAME" stop
    assert_success
}

@test "with PIHX_LOCK_WAIT a changing command waits for the holder, then runs" {
    hold_lock
    ( sleep 3; kill "$HOLDER" ) 3>&- &
    run env PIHX_LOCK_WAIT=30 "$BIN/openmrs-docker" "$NAME" stop
    assert_success
    assert_output --partial "waiting up to 30s"
}

@test "with PIHX_LOCK_WAIT a command that waits too long fails, naming the holder" {
    hold_lock
    run env PIHX_LOCK_WAIT=2 "$BIN/openmrs-docker" "$NAME" stop
    assert_failure
    assert_output --partial "$NAME is still busy after 2s: initialize (pid"
}

@test "PIHX_LOCK_WAIT must be a number of seconds" {
    run env PIHX_LOCK_WAIT=soon "$BIN/openmrs-docker" "$NAME" stop
    assert_failure
    assert_output --partial "PIHX_LOCK_WAIT must be a number of seconds"
}
