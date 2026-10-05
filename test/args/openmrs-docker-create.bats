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

@test "a required variable missing from env stops commands with a hint, and sync adds only required ones" {
    NAME="$(instance)"
    local dir
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    dir="$OPENMRS_DOCKER_HOME/$NAME"
    # a required variable, and a server option deliberately dropped (not required by the fragment)
    sed -i '/^OPENMRS_DB_MEMORY_LIMIT=/d; /^OPENMRS_DB_OPT_net_read_timeout=/d; /^# Server options/d' "$dir/env"
    run docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" config -q
    assert_failure
    assert_output --partial "required variable OPENMRS_DB_MEMORY_LIMIT is missing a value"
    run "$BIN/openmrs-docker" "$NAME" status
    assert_failure
    assert_output --partial "is missing OPENMRS_DB_MEMORY_LIMIT"
    assert_output --partial "$NAME sync"
    run "$BIN/openmrs-docker" "$NAME" sync
    assert_success
    assert_output --partial "Added to env: OPENMRS_DB_MEMORY_LIMIT"
    run grep -c "^OPENMRS_DB_MEMORY_LIMIT='2g'$" "$dir/env"
    assert_output 1
    run grep -c "^OPENMRS_DB_OPT_net_read_timeout=" "$dir/env"
    assert_output 0
    # nothing more to add, and no comment lines re-added
    run "$BIN/openmrs-docker" "$NAME" sync
    refute_output --partial "Added to env"
    run grep -c '^# Server options' "$dir/env"
    assert_output 0
    run "$BIN/openmrs-docker" "$NAME" status
    assert_success
}

@test "create refuses a name Compose can't use as its project name, and creates nothing" {
    NAME="$(instance)"
    local bad
    for bad in "$NAME-Upper" "$NAME/sub" ".$NAME" "-$NAME"; do
        run "$BIN/openmrs-docker" create "$bad"
        assert_failure
        assert_output --partial "must be lowercase letters, digits, '-' and '_'"
        [ ! -e "$OPENMRS_DOCKER_HOME/$bad" ]
    done
}

@test "a SERVICE_NAME in env that Compose would change is refused, except by destroy" {
    NAME="$(instance)"
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    sed -i "s/^SERVICE_NAME=.*/SERVICE_NAME='$NAME-Upper'/" "$OPENMRS_DOCKER_HOME/$NAME/env"
    run "$BIN/openmrs-docker" "$NAME" status
    assert_failure
    assert_output --partial "SERVICE_NAME '$NAME-Upper'"
    run "$BIN/openmrs-docker" "$NAME" destroy --force
    assert_success
    [ ! -e "$OPENMRS_DOCKER_HOME/$NAME" ]
}

@test "a container-env line with trailing whitespace or tabs passes only the variables it names" {
    NAME="$(instance)"
    # A copy of the tool, so its service defaults can be edited.
    local tool="$BATS_TEST_TMPDIR/tool" dir
    mkdir -p "$tool" && cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/docker" "$REPO_ROOT/utils" "$tool/"
    sed -i "s/^# container-env:.*/# container-env:\tOPENMRS_DB_OPT_ \t /" "$tool/docker/services/openmrs-db.env.defaults"
    SERVICES=openmrs-db "$tool/bin/openmrs-docker" create "$NAME" >/dev/null
    dir="$OPENMRS_DOCKER_HOME/$NAME"
    run grep -c '^OPENMRS_DB_OPT_' "$dir/openmrs-db.env"
    refute_output 0
    run grep -v -e '^#' -e '^OPENMRS_DB_OPT_' "$dir/openmrs-db.env"
    assert_output ''
}

@test "list shows only instance directories" {
    NAME="$(instance)"
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    mkdir -p "$OPENMRS_DOCKER_HOME/$NAME-not-an-instance"
    run "$BIN/openmrs-docker" list
    assert_success
    assert_line "$NAME"
    refute_line "$NAME-not-an-instance"
    rmdir "$OPENMRS_DOCKER_HOME/$NAME-not-an-instance"
}

@test "add-service leaves the instance unchanged when the result isn't valid Compose" {
    NAME="$(instance)"
    SERVICES=openmrs-db,openmrs "$BIN/openmrs-docker" create "$NAME" >/dev/null
    cp "$OPENMRS_DOCKER_HOME/$NAME/env" "$BATS_TEST_TMPDIR/env.before"
    # the mediator depends on services from the openhim fragment, which isn't attached
    run "$BIN/openmrs-docker" "$NAME" add-service openhim-advapacs-mediator
    assert_failure
    assert_output --partial "leaves $NAME's services invalid"
    [ ! -e "$OPENMRS_DOCKER_HOME/$NAME/openhim-advapacs-mediator.yaml" ]
    cmp "$BATS_TEST_TMPDIR/env.before" "$OPENMRS_DOCKER_HOME/$NAME/env"
    run "$BIN/openmrs-docker" "$NAME" status
    assert_success
}

@test "add-service openmrs names OPENMRS_IMAGE_NAME when it isn't set" {
    NAME="$(instance)"
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run env -u OPENMRS_IMAGE_NAME "$BIN/openmrs-docker" "$NAME" add-service openmrs
    assert_failure
    assert_output --partial "OPENMRS_IMAGE_NAME must be set"
    [ ! -e "$OPENMRS_DOCKER_HOME/$NAME/openmrs.yaml" ]
}

@test "reset-openmrs-db-accounts refuses an instance with no openmrs-db service" {
    NAME="$(instance)"
    SERVICES=openhim "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run "$BIN/openmrs-docker" "$NAME" reset-openmrs-db-accounts
    assert_failure
    assert_output --partial "has no openmrs-db service"
}

@test "fingerprint rejects an option it doesn't take, and an instance with no db-data yet" {
    NAME="$(instance)"
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run "$BIN/openmrs-docker" "$NAME" fingerprint --bogus
    assert_failure
    assert_output --partial "unknown option '--bogus'"
    run "$BIN/openmrs-docker" "$NAME" fingerprint
    assert_failure
    assert_output --partial "${NAME}_db-data doesn't exist"
}

@test "a command refuses options it doesn't take, and an unknown command is named" {
    NAME="$(instance)"
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    run "$BIN/openmrs-docker" "$NAME" stop --force
    assert_failure
    assert_output --partial "unknown option '--force' for stop"
    run "$BIN/openmrs-docker" "$NAME" destroy --dev
    assert_failure
    assert_output --partial "unknown option '--dev' for destroy"
    run "$BIN/openmrs-docker" "$NAME" add-service
    assert_failure
    assert_output --partial "add-service <service>"
    run "$BIN/openmrs-docker" "$NAME" frobnicate
    assert_failure
    assert_output --partial "unknown command 'frobnicate'"
    assert [ -d "$OPENMRS_DOCKER_HOME/$NAME" ]
}

@test "sqlserver needs SQLSERVER_SA_PASSWORD: create and add-service refuse without it, changing nothing" {
    NAME="$(instance)"
    run env -u SQLSERVER_SA_PASSWORD SERVICES=openmrs-db,sqlserver "$BIN/openmrs-docker" create "$NAME"
    assert_failure
    assert_output --partial 'SQLSERVER_SA_PASSWORD: must be set'
    assert [ ! -e "$OPENMRS_DOCKER_HOME/$NAME" ]
    SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    cp "$OPENMRS_DOCKER_HOME/$NAME/env" "$BATS_TEST_TMPDIR/env.before"
    run env -u SQLSERVER_SA_PASSWORD "$BIN/openmrs-docker" "$NAME" add-service sqlserver
    assert_failure
    assert_output --partial 'SQLSERVER_SA_PASSWORD: must be set'
    assert [ ! -e "$OPENMRS_DOCKER_HOME/$NAME/sqlserver.yaml" ]
    cmp "$BATS_TEST_TMPDIR/env.before" "$OPENMRS_DOCKER_HOME/$NAME/env"
    SQLSERVER_SA_PASSWORD='Pw-1234x' run "$BIN/openmrs-docker" "$NAME" add-service sqlserver
    assert_success
    run grep -c "^SQLSERVER_SA_PASSWORD='Pw-1234x'$" "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output 1
}

@test "create writes the instance's own defaults, and sync puts back a required one deleted from env" {
    NAME="$(instance)"
    TZ=Africa/Maseru SERVICES=openmrs-db "$BIN/openmrs-docker" create "$NAME" >/dev/null
    local env="$OPENMRS_DOCKER_HOME/$NAME/env"
    run grep -E '^(TZ|SEED_IMAGE_TAG|DISTRO_SOURCE_DIR)=' "$env"
    assert_output "$(printf "%s\n" "TZ='Africa/Maseru'" "DISTRO_SOURCE_DIR=''" "SEED_IMAGE_TAG='latest'")"
    sed -i '/^TZ=/d' "$env"
    run "$BIN/openmrs-docker" "$NAME" status
    assert_failure
    assert_output --partial "is missing TZ"
    run env -u TZ "$BIN/openmrs-docker" "$NAME" sync
    assert_success
    assert_output --partial "Added to env: TZ"
    run grep '^TZ=' "$env"
    assert_output "TZ='UTC'"
}

@test "a default can refer to a variable an earlier line of the same .env.defaults sets" {
    NAME="$(instance)"   # for teardown
    printf '%s\n' 'A_USER="${A_USER:-petl}"' 'B_USER="${B_USER:-${A_USER}}"' > "$BATS_TEST_TMPDIR/x.env.defaults"
    run bash -c "source '$REPO_ROOT/utils/lib/common.sh'; source '$REPO_ROOT/lib/openmrs-docker/env.sh';
        render_env_defaults '$BATS_TEST_TMPDIR/x.env.defaults'"
    assert_success
    assert_line "A_USER='petl'"
    assert_line "B_USER='petl'"
}

@test "adding petl declares its MySQL account and SQL Server login from its own variables" {
    NAME="$(instance)"
    PETL_MYSQL_PASSWORD='My-pw-1' PETL_SQLSERVER_PASSWORD='Sql-pw-1' SQLSERVER_SA_PASSWORD='Sa-pw-1' \
        SERVICES=openmrs-db,petl,sqlserver create_instance "$NAME"
    run cat "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_line "OPENMRS_DB_ACCOUNT_PETL_USER='petl'"
    assert_line "OPENMRS_DB_ACCOUNT_PETL_PASSWORD='My-pw-1'"
    assert_line "OPENMRS_DB_ACCOUNT_PETL_GRANTS='ALL ON *.*'"
    assert_line "SQLSERVER_LOGIN_PETL_USER='petl'"
    assert_line "SQLSERVER_LOGIN_PETL_PASSWORD='Sql-pw-1'"
    assert_line "SQLSERVER_LOGIN_PETL_DATABASES='openmrs_reporting'"
    refute_output --partial '# run-service:'
}

@test "petl's MySQL options name the time zone, left for PETL to resolve as its JVM's" {
    NAME="$(instance)"
    PETL_MYSQL_PASSWORD='My-pw-1' SERVICES=openmrs-db,petl create_instance "$NAME"
    local expected="PETL_MYSQL_OPTIONS='autoReconnect=true&sessionVariables=default_storage_engine%3DInnoDB&useUnicode=true&characterEncoding=UTF-8&useLegacyDatetimeCode=false&serverTimezone=\${user.timezone}'"
    run grep '^PETL_MYSQL_OPTIONS=' "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output "$expected"
    run grep '^PETL_MYSQL_OPTIONS=' "$OPENMRS_DOCKER_HOME/$NAME/petl.env"
    assert_output "$expected"
}

@test "petl needs PETL_MYSQL_PASSWORD" {
    NAME="$(instance)"
    run env -u PETL_MYSQL_PASSWORD PETL_SQLSERVER_PASSWORD=x SERVICES=openmrs-db,petl "$BIN/openmrs-docker" create "$NAME"
    assert_failure
    assert_output --partial 'PETL_MYSQL_PASSWORD: must be set'
}

@test "petl doesn't need PETL_SQLSERVER_PASSWORD (an ETL writing only to MySQL)" {
    NAME="$(instance)"
    run env -u PETL_SQLSERVER_PASSWORD PETL_MYSQL_PASSWORD=My-pw-1 SERVICES=openmrs-db,petl "$BIN/openmrs-docker" create "$NAME"
    assert_success
    run grep '^PETL_SQLSERVER_PASSWORD=' "$OPENMRS_DOCKER_HOME/$NAME/env"
    assert_output "PETL_SQLSERVER_PASSWORD=''"
}

@test "account declarations go to openmrs-db-accounts' own env file, not openmrs-db's" {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    local dir="$OPENMRS_DOCKER_HOME/$NAME"
    printf "OPENMRS_DB_ACCOUNT_RPT_USER='reports'\nOPENMRS_DB_ACCOUNT_RPT_PASSWORD='Pw-1'\n" >> "$dir/env"
    "$BIN/openmrs-docker" "$NAME" status >/dev/null 2>&1 || true
    run grep -c '^OPENMRS_DB_ACCOUNT_' "$dir/openmrs-db.env"
    assert_output 0
    run grep -c '^OPENMRS_DB_ACCOUNT_' "$dir/openmrs-db-accounts.env"
    assert_output 2
    run grep -c '^OPENMRS_DB_OPT_' "$dir/openmrs-db-accounts.env"
    assert_output 0
}

@test "petl works without sqlserver: add-service petl, and remove-service sqlserver from an instance with petl" {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    run env PETL_MYSQL_PASSWORD=My-pw-1 PETL_SQLSERVER_PASSWORD=Sql-pw-1 PETL_SQLSERVER_HOST=reports.example.org \
        "$BIN/openmrs-docker" "$NAME" add-service petl
    assert_success
    destroy_instance "$NAME"
    PETL_MYSQL_PASSWORD=My-pw-1 PETL_SQLSERVER_PASSWORD=Sql-pw-1 SQLSERVER_SA_PASSWORD=Sa-pw-1 \
        SERVICES=openmrs-db,petl,sqlserver create_instance "$NAME"
    run "$BIN/openmrs-docker" "$NAME" remove-service sqlserver
    assert_success
}
