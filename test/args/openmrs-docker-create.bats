#!/usr/bin/env bats
# create captures any OMRS_EXTRA_* and OPENMRS_DB_OPT_* variable from the calling shell into the
# instance's env file -- see openmrs.yaml's and openmrs-db.yaml's env_file for how these reach the
# containers.

load ../helpers

teardown() {
    rm -rf "${OPENMRS_DOCKER_HOME:?}/${NAME:?}"
}

@test "captures OMRS_EXTRA_* variables from the environment into the instance env file" {
    NAME="$(instance)"
    OMRS_EXTRA_pihmalawi_warehouse_connection_url="jdbc:mysql://openmrs-db:3306/openmrs_warehouse" \
        "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial 'OMRS_EXTRA_pihmalawi_warehouse_connection_url="jdbc:mysql://openmrs-db:3306/openmrs_warehouse"'
}

@test "only matches variable names that actually start with OMRS_EXTRA_" {
    NAME="$(instance)"
    SOME_OMRS_EXTRA_LOOKALIKE=nope OMRS_EXTRA_real=yes "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial 'OMRS_EXTRA_real="yes"'
    refute_output --partial 'LOOKALIKE'
}

@test "writes the default OPENMRS_DB_OPT_* server options, overridable from the environment" {
    NAME="$(instance)"
    OPENMRS_DB_OPT_max_allowed_packet=256M "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial 'OPENMRS_DB_OPT_character_set_server="utf8"'
    assert_output --partial 'OPENMRS_DB_OPT_max_allowed_packet="256M"'
    run grep -c '^OPENMRS_DB_OPT_max_allowed_packet=' "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output 1
}

@test "captures OPENMRS_DB_OPT_* variables with no default, including empty ones" {
    NAME="$(instance)"
    OPENMRS_DB_OPT_log_bin=mysql-bin OPENMRS_DB_OPT_skip_name_resolve= "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial 'OPENMRS_DB_OPT_log_bin="mysql-bin"'
    assert_output --partial 'OPENMRS_DB_OPT_skip_name_resolve=""'
}

@test "add-service doesn't duplicate lower-case env names already in the env file" {
    NAME="$(instance)"
    SERVICES=openmrs "$BIN/openmrs-docker" create "$NAME" >/dev/null
    "$BIN/openmrs-docker" "$NAME" add-service openmrs-db >/dev/null
    "$BIN/openmrs-docker" "$NAME" add-service openmrs-db >/dev/null 2>&1 || true
    run grep -c '^OPENMRS_DB_OPT_character_set_server=' "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output 1
}
