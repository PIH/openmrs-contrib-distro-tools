#!/usr/bin/env bats
# create captures any OMRS_EXTRA_* and OPENMRS_DB_OPT_* variable from the calling shell into the
# instance's env file -- see openmrs.yaml's and openmrs-db.yaml's env_file for how these reach the
# containers. Every value is written single-quoted, so bash and Docker Compose both read it literally.

load ../helpers

teardown() {
    rm -rf "${OPENMRS_DOCKER_HOME:?}/${NAME:?}"
}

@test "captures OMRS_EXTRA_* variables from the environment into the instance env file" {
    NAME="$(instance)"
    OMRS_EXTRA_pihmalawi_warehouse_connection_url="jdbc:mysql://openmrs-db:3306/openmrs_warehouse" \
        "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial "OMRS_EXTRA_pihmalawi_warehouse_connection_url='jdbc:mysql://openmrs-db:3306/openmrs_warehouse'"
}

@test "only matches variable names that actually start with OMRS_EXTRA_" {
    NAME="$(instance)"
    SOME_OMRS_EXTRA_LOOKALIKE=nope OMRS_EXTRA_real=yes "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial "OMRS_EXTRA_real='yes'"
    refute_output --partial 'LOOKALIKE'
}

@test "writes the default OPENMRS_DB_OPT_* server options, overridable from the environment" {
    NAME="$(instance)"
    OPENMRS_DB_OPT_max_allowed_packet=256M "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial "OPENMRS_DB_OPT_character_set_server='utf8'"
    assert_output --partial "OPENMRS_DB_OPT_max_allowed_packet='256M'"
    run grep -c '^OPENMRS_DB_OPT_max_allowed_packet=' "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output 1
}

@test "captures OPENMRS_DB_OPT_* variables with no default, including empty ones" {
    NAME="$(instance)"
    OPENMRS_DB_OPT_log_bin=mysql-bin OPENMRS_DB_OPT_skip_name_resolve= "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output --partial "OPENMRS_DB_OPT_log_bin='mysql-bin'"
    assert_output --partial "OPENMRS_DB_OPT_skip_name_resolve=''"
}

@test "add-service doesn't duplicate lower-case env names already in the env file" {
    NAME="$(instance)"
    SERVICES=openmrs "$BIN/openmrs-docker" create "$NAME" >/dev/null
    "$BIN/openmrs-docker" "$NAME" add-service openmrs-db >/dev/null
    "$BIN/openmrs-docker" "$NAME" add-service openmrs-db >/dev/null 2>&1 || true
    run grep -c '^OPENMRS_DB_OPT_character_set_server=' "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output 1
}

@test "values with \$, double quotes, backticks and backslashes read back unchanged in bash and Compose" {
    NAME="$(instance)"
    local secret='p$HOME"x`id`\z#1' dir
    OPENMRS_DB_ROOT_PASSWORD="$secret" OMRS_EXTRA_some_secret="$secret" "$BIN/openmrs-docker" create "$NAME" >/dev/null
    dir="$OPENMRS_DOCKER_HOME/$NAME"
    run bash -c 'set -a; source "$1"; printf "%s\n%s" "$OPENMRS_DB_ROOT_PASSWORD" "$OMRS_EXTRA_some_secret"' _ "$dir/env"
    assert_output "$secret"$'\n'"$secret"
    run docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" -f "$dir/openmrs.yaml" config --format json
    assert_success
    run jq -r '.services["openmrs-db"].environment.MYSQL_ROOT_PASSWORD, .services.openmrs.environment.OMRS_EXTRA_some_secret' <<< "$output"
    # config prints a literal $ as $$ (its own escape); the container gets a single $
    assert_output "${secret//\$/\$\$}"$'\n'"${secret//\$/\$\$}"
}

@test "refuses a value with a single quote or newline, and leaves no instance directory behind" {
    NAME="$(instance)"
    run env OPENMRS_DB_PASSWORD="it's" "$BIN/openmrs-docker" create "$NAME"
    assert_failure
    assert_output --partial "OPENMRS_DB_PASSWORD contains a single quote or newline"
    [ ! -e "$OPENMRS_DOCKER_HOME/$NAME" ]
    run env OMRS_EXTRA_x=$'a\nb' "$BIN/openmrs-docker" create "$NAME"
    assert_failure
    assert_output --partial "OMRS_EXTRA_x contains a single quote or newline"
    [ ! -e "$OPENMRS_DOCKER_HOME/$NAME" ]
}

@test "add-service refuses a single-quoted value without changing the instance" {
    NAME="$(instance)"
    SERVICES=openmrs-db,openmrs "$BIN/openmrs-docker" create "$NAME" >/dev/null
    cp "$OPENMRS_DOCKER_HOME/$NAME/env" "$BATS_TEST_TMPDIR/env.before"
    run env OPENHIM_PASSWORD="it's" "$BIN/openmrs-docker" "$NAME" add-service openhim
    assert_failure
    assert_output --partial "OPENHIM_PASSWORD contains a single quote or newline"
    [ ! -e "$OPENMRS_DOCKER_HOME/$NAME/openhim.yaml" ]
    cmp "$BATS_TEST_TMPDIR/env.before" "$OPENMRS_DOCKER_HOME/$NAME/env"
}

@test "each container gets only its own variables from env, not every instance secret" {
    NAME="$(instance)"
    local dir
    OMRS_EXTRA_foo=bar SERVICES=openmrs-db,openmrs,openhim "$BIN/openmrs-docker" create "$NAME" >/dev/null
    dir="$OPENMRS_DOCKER_HOME/$NAME"
    run stat -c %a "$dir/openmrs.env" "$dir/openmrs-db.env"
    assert_output $'600\n600'
    run docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" -f "$dir/openmrs.yaml" -f "$dir/openhim.yaml" config --format json
    assert_success
    local config=$output
    run jq -r '.services.openmrs.environment | keys[]' <<< "$config"
    assert_line OMRS_EXTRA_foo
    refute_line --regexp '^(OPENMRS_DB_ROOT_PASSWORD|OPENMRS_DB_OPT_.*|OPENHIM_PASSWORD)$'
    run jq -r '.services["openmrs-db"].environment | keys[]' <<< "$config"
    assert_line OPENMRS_DB_OPT_character_set_server
    refute_line --regexp '^(OMRS_EXTRA_foo|OPENHIM_PASSWORD|OPENMRS_DB_ROOT_PASSWORD)$'
}

@test "a later edit to env reaches the container env files on the next command" {
    NAME="$(instance)"
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    echo "OPENMRS_DB_OPT_long_query_time='7'" >> "$OPENMRS_DOCKER_HOME/$NAME/env"
    "$BIN/openmrs-docker" "$NAME" status >/dev/null
    run cat "$OPENMRS_DOCKER_HOME/$NAME/openmrs-db.env"
    assert_output --partial "OPENMRS_DB_OPT_long_query_time='7'"
}

@test "only services with a container-env directive get a generated env file, and the directive stays out of env" {
    NAME="$(instance)"
    local dir
    SERVICES=openmrs-db,openmrs,openhim "$BIN/openmrs-docker" create "$NAME" >/dev/null
    dir="$OPENMRS_DOCKER_HOME/$NAME"
    [ -f "$dir/openmrs.env" ] && [ -f "$dir/openmrs-db.env" ]
    [ ! -e "$dir/openhim.env" ]
    run grep -c 'container-env' "$dir/env"
    assert_output 0
    # A generated file whose service no longer declares container-env is removed on the next command.
    echo "OPENHIM_PASSWORD='stale'" > "$dir/openhim.env"
    "$BIN/openmrs-docker" "$NAME" status >/dev/null
    [ ! -e "$dir/openhim.env" ]
}
