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
    run "$BIN/pihx" "$NAME" compose exec no-such-service true
    assert_failure
    run "$BIN/pihx" "$NAME" compose version --short
    assert_success
}

@test "compose is in pihx's help, and works the same through openmrs-docker" {
    run "$BIN/pihx" help
    assert_line --partial "compose <subcommand>"
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

@test "compose refuses what changes the instance, naming the managed command, and runs no docker" {
    local sub
    for sub in up down run rm restart pull; do
        PIHX_DEBUG=1 run --separate-stderr "$BIN/pihx" "$NAME" compose "$sub"
        assert_failure 2
        [[ $stderr == "error: "*"pihx $NAME "* ]]
        # No docker compose was run (the echo would show it), so nothing was created.
        [[ $stderr != *"+ docker"* ]]
    done
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
}

@test "compose config refuses to write a file, so an env file can't be overwritten" {
    local before
    before=$(cat "$PIHX_HOME/$NAME"/*.env)
    PIHX_DEBUG=1 run --separate-stderr "$BIN/pihx" "$NAME" compose config -o "$PIHX_HOME/$NAME/instance.env"
    assert_failure 2
    [[ $stderr == *"-o/--output could overwrite"* ]]
    [[ $stderr != *"+ docker"* ]]
    assert_equal "$(cat "$PIHX_HOME/$NAME"/*.env)" "$before"
}

@test "compose takes the subcommand first" {
    run "$BIN/pihx" "$NAME" compose -f x.yaml config
    assert_failure 2
    assert_output --partial "subcommand first"
}
