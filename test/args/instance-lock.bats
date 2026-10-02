#!/usr/bin/env bats
# Commands that change an instance hold its lock, and refuse while another command holds it: puppet
# runs `pull && start` on every apply, which mustn't happen part way through e.g. an initialize.

load ../helpers

setup() {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    LOCK="$OPENMRS_DOCKER_HOME/$NAME/.lock"
}
teardown() {
    [ -z "${HOLDER:-}" ] || kill "$HOLDER" 2>/dev/null || true
    destroy_instance "$NAME"
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
    for cmd in start stop restart update pull sync reset-openmrs-db-accounts destroy; do
        if [ "$cmd" = destroy ]; then run "$BIN/openmrs-docker" "$NAME" destroy --force
        else run "$BIN/openmrs-docker" "$NAME" "$cmd"; fi
        assert_failure
        assert_output --partial "$NAME is busy: initialize (pid"
    done
    run "$BIN/openmrs-docker" "$NAME" add-service openmrs
    assert_failure
    assert_output --partial "is busy"
    [ -d "$OPENMRS_DOCKER_HOME/$NAME" ]
}

@test "run-service refuses while the lock is held, but doesn't hold it itself" {
    hold_lock
    run "$BIN/openmrs-docker" "$NAME" run-service openmrs-db true
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
    run "$BIN/openmrs-docker" "$NAME" sync
    assert_success
    run "$BIN/openmrs-docker" "$NAME" status
    refute_output --partial "Busy:"
    # a failed command releases it too
    run_initialize "$NAME" SEED_IMAGE_NAME=
    assert_failure
    run "$BIN/openmrs-docker" "$NAME" sync
    assert_success
}

@test "with OPENMRS_DOCKER_LOCK_WAIT a changing command waits for the holder, then runs" {
    hold_lock
    ( sleep 3; kill "$HOLDER" ) 3>&- &
    run env OPENMRS_DOCKER_LOCK_WAIT=30 "$BIN/openmrs-docker" "$NAME" sync
    assert_success
    assert_output --partial "waiting up to 30s"
}

@test "with OPENMRS_DOCKER_LOCK_WAIT a command that waits too long fails, naming the holder" {
    hold_lock
    run env OPENMRS_DOCKER_LOCK_WAIT=2 "$BIN/openmrs-docker" "$NAME" sync
    assert_failure
    assert_output --partial "$NAME is still busy after 2s: initialize (pid"
}

@test "OPENMRS_DOCKER_LOCK_WAIT must be a number of seconds" {
    run env OPENMRS_DOCKER_LOCK_WAIT=soon "$BIN/openmrs-docker" "$NAME" sync
    assert_failure
    assert_output --partial "OPENMRS_DOCKER_LOCK_WAIT must be a number of seconds"
}
