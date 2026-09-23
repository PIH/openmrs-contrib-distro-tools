#!/usr/bin/env bats
# create captures any OMRS_EXTRA_* variable from the calling shell verbatim into the instance's env
# file, so a distro can supply extra OpenMRS runtime properties without an explicit entry anywhere
# in distro-tools -- openmrs.yaml's own `env_file: - env` is what gets these into the container.

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
