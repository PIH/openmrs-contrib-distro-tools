#!/usr/bin/env bats
# pihx <instance> compose <args...> runs docker compose with the instance's project name and files,
# passes its arguments through and returns its status. `config` needs no containers.

load ../helpers

setup() {
    NAME="$(instance)"
    create_instance "$NAME"
}
teardown() { destroy_instance "$NAME"; common_teardown; }

@test "compose config runs docker compose with the instance's project name and files" {
    run "$BIN/pihx" "$NAME" compose config openmrs-db
    assert_success
    # The resolved model of the instance's project, and the one service asked for.
    assert_line "name: $NAME"
    assert_line "  openmrs-db:"
    refute_line "  openmrs:"
}

@test "compose returns docker compose's exit status" {
    run "$BIN/pihx" "$NAME" compose no-such-subcommand
    assert_failure
    run "$BIN/pihx" "$NAME" compose version --short
    assert_success
}

@test "compose is in pihx's help, and works the same through openmrs-docker" {
    run "$BIN/pihx" help
    assert_line --partial "compose <args...>"
    run "$BIN/openmrs-docker" "$NAME" compose config --services
    assert_success
    assert_line openmrs-db
}

@test "PIHX_DEBUG=1 echoes the docker compose command line to stderr, without values" {
    PIHX_DEBUG=1 PETL_MYSQL_PASSWORD=sekrit-value run --separate-stderr "$BIN/pihx" "$NAME" compose config openmrs-db
    assert_success
    local echoed
    echoed=$(printf '%s\n' "${stderr_lines[@]}" | grep '^+ docker compose ')
    [[ $echoed == *" -p $NAME "* ]]
    [[ $echoed == *" -f $REPO_ROOT/services/openmrs-db/compose.yaml "* ]]
    [[ $echoed == *" config openmrs-db" ]]
    [[ $echoed != *sekrit-value* ]]
    run --separate-stderr "$BIN/pihx" "$NAME" compose config --services
    assert_success
    assert_equal "${#stderr_lines[@]}" 0
}
