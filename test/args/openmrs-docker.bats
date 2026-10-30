#!/usr/bin/env bats
# openmrs-docker is a pihx extension: pihx's command line, where a command it doesn't add or change
# is pihx's own, and nothing else (no old command names or argument orders).

load ../helpers

setup() {
    NAME="$(instance)"
    create_instance "$NAME"
}
teardown() {
    [ -z "${SHARED_PIHX_HOME-}" ] || export PIHX_HOME=$SHARED_PIHX_HOME
    destroy_instance "$NAME"
    common_teardown
}

# Runs <args> through openmrs-docker and pihx; fails unless both give the same status and output.
# Leaves pihx's in status and output.
assert_same_as_pihx() { # <args...>
    run "$BIN/openmrs-docker" "$@"
    local docker_status=$status docker_output=$output
    run "$BIN/pihx" "$@"
    assert_equal "$docker_status" "$status"
    assert_equal "$docker_output" "$output"
}

@test "a command the extension doesn't define is pihx's, with the same output" {
    assert_same_as_pihx "$NAME" config
    assert_same_as_pihx "$NAME" openmrs-db
    assert_same_as_pihx "$NAME" status
    # list shows every instance in PIHX_HOME, which parallel tests share (one created between the two
    # runs would differ), so it runs in a PIHX_HOME only this test uses.
    SHARED_PIHX_HOME=$PIHX_HOME
    export PIHX_HOME="$BATS_TEST_TMPDIR/list-home"
    mkdir -p "$PIHX_HOME"
    create_instance "$NAME-list"
    assert_same_as_pihx list
    destroy_instance "$NAME-list"
    export PIHX_HOME=$SHARED_PIHX_HOME
}

@test "create takes the instance first, as pihx's does" {
    local other
    other="$(instance other)"
    run "$BIN/openmrs-docker" "$other" create --services=openmrs-db
    assert_success
    assert [ -f "$(env_file_of "$other" openmrs-db)" ]
    destroy_instance "$other"
}

@test "the old create order and the dropped commands are pihx's usual errors" {
    assert_same_as_pihx create "$NAME"
    assert_failure 2
    assert_output --partial "unknown command '$NAME'"
    local command
    for command in fingerprint reset-openmrs-db-accounts sync; do
        assert_same_as_pihx "$NAME" "$command"
        assert_failure 2
        assert_output --partial "unknown command '$command'"
    done
}

@test "help is pihx's, and then what the extension adds" {
    run "$BIN/pihx" help
    local pihx_help=$output
    run "$BIN/openmrs-docker" help
    assert_success
    assert_output --partial "$pihx_help"
    assert_output --partial "openmrs-docker is pihx with OpenMRS development commands"
}
