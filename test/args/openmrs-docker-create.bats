#!/usr/bin/env bats
# openmrs-docker <name> create (pihx's, with openmrs-db,openmrs by default) captures OMRS_EXTRA_*,
# OPENMRS_DB_OPT_* and each service's own variables from the calling shell into the instance's env
# files (one per service, plus instance.env), each value single-quoted, so bash and Docker Compose
# both read it literally; what isn't set comes from the services' defaults.

load ../helpers

teardown() {
    rm -rf "${PIHX_HOME:?}/${NAME:?}"
}

# A copy of the instance's env files, to check that a refused command changed none of them.
snapshot_env_files() {
    mkdir -p "$BATS_TEST_TMPDIR/before"
    cp "$PIHX_HOME/$NAME"/*.env "$BATS_TEST_TMPDIR/before/"
}
assert_env_files_unchanged() {
    local f
    for f in "$BATS_TEST_TMPDIR/before"/*.env; do
        cmp "$f" "$PIHX_HOME/$NAME/$(basename "$f")" || fail "$(basename "$f") changed"
    done
    assert_equal "$(cd "$PIHX_HOME/$NAME" && ls ./*.env)" "$(cd "$BATS_TEST_TMPDIR/before" && ls ./*.env)"
}

@test "captures OMRS_EXTRA_* variables from the environment into openmrs.env" {
    NAME="$(instance)"
    OMRS_EXTRA_pihmalawi_warehouse_connection_url="jdbc:mysql://openmrs-db:3306/openmrs_warehouse" \
        "$BIN/openmrs-docker" "$NAME" create >/dev/null 2>&1
    run cat "$(env_file_of "$NAME" openmrs)"
    assert_output --partial "OMRS_EXTRA_pihmalawi_warehouse_connection_url='jdbc:mysql://openmrs-db:3306/openmrs_warehouse'"
}

@test "only matches variable names that actually start with OMRS_EXTRA_" {
    NAME="$(instance)"
    SOME_OMRS_EXTRA_LOOKALIKE=nope OMRS_EXTRA_real=yes "$BIN/openmrs-docker" "$NAME" create >/dev/null 2>&1
    run cat "$(env_file_of "$NAME" openmrs)"
    assert_output --partial "OMRS_EXTRA_real='yes'"
    run cat "$PIHX_HOME/$NAME"/*.env
    refute_output --partial 'LOOKALIKE'
}

@test "the default OPENMRS_DB_OPT_* server options apply, and one set in the environment overrides its default" {
    NAME="$(instance)"
    OPENMRS_DB_OPT_max_allowed_packet=256M "$BIN/openmrs-docker" "$NAME" create >/dev/null 2>&1
    run instance_config "$NAME"
    assert_line "OPENMRS_DB_OPT_character_set_server=utf8"
    assert_line "OPENMRS_DB_OPT_max_allowed_packet=256M"
    # only the instance's own value is written, once
    run grep '^OPENMRS_DB_OPT_max_allowed_packet=' "$(env_file_of "$NAME" openmrs-db)"
    assert_output "OPENMRS_DB_OPT_max_allowed_packet='256M'"
    run grep -c '^OPENMRS_DB_OPT_character_set_server=' "$(env_file_of "$NAME" openmrs-db)"
    assert_output 0
}

@test "captures OPENMRS_DB_OPT_* variables with no default, including empty ones" {
    NAME="$(instance)"
    OPENMRS_DB_OPT_log_bin=mysql-bin OPENMRS_DB_OPT_skip_name_resolve= "$BIN/openmrs-docker" "$NAME" create >/dev/null 2>&1
    run cat "$(env_file_of "$NAME" openmrs-db)"
    assert_output --partial "OPENMRS_DB_OPT_log_bin='mysql-bin'"
    assert_output --partial "OPENMRS_DB_OPT_skip_name_resolve=''"
}

@test "add-service doesn't duplicate lower-case env names, and refuses a service the instance has" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openhim >/dev/null 2>&1
    "$BIN/openmrs-docker" "$NAME" add-service openmrs-db >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" add-service openmrs-db
    assert_failure
    assert_output --partial "already has openmrs-db"
    # OPENMRS_DB_OPT_innodb_buffer_pool_size is set by the test helpers
    run grep -c '^OPENMRS_DB_OPT_innodb_buffer_pool_size=' "$(env_file_of "$NAME" openmrs-db)"
    assert_output 1
}

@test "values with \$, double quotes, backticks and backslashes read back unchanged in bash and Compose" {
    NAME="$(instance)"
    local secret='p$HOME"x`id`\z#1'
    OPENMRS_DB_ROOT_PASSWORD="$secret" OMRS_EXTRA_some_secret="$secret" "$BIN/openmrs-docker" "$NAME" create >/dev/null 2>&1
    run bash -c 'set -a; source "$1"; source "$2"; printf "%s\n%s" "$OPENMRS_DB_ROOT_PASSWORD" "$OMRS_EXTRA_some_secret"' _ \
        "$(env_file_of "$NAME" openmrs-db)" "$(env_file_of "$NAME" openmrs)"
    assert_output "$secret"$'\n'"$secret"
    run instance_compose_of "$NAME" config --format json
    assert_success
    run jq -r '.services["openmrs-db"].environment.MYSQL_ROOT_PASSWORD, .services.openmrs.environment.OMRS_EXTRA_some_secret' <<< "$output"
    # config prints a literal $ as $$ (its own escape); the container gets a single $
    assert_output "${secret//\$/\$\$}"$'\n'"${secret//\$/\$\$}"
}

@test "refuses a value with a single quote or newline, and leaves no instance directory behind" {
    NAME="$(instance)"
    run env OPENMRS_DB_PASSWORD="it's" "$BIN/openmrs-docker" "$NAME" create
    assert_failure
    assert_output --partial "OPENMRS_DB_PASSWORD contains a single quote or newline"
    [ ! -e "$PIHX_HOME/$NAME" ]
    run env OMRS_EXTRA_x=$'a\nb' "$BIN/openmrs-docker" "$NAME" create
    assert_failure
    assert_output --partial "OMRS_EXTRA_x contains a single quote or newline"
    [ ! -e "$PIHX_HOME/$NAME" ]
}

@test "add-service refuses a single-quoted value without changing the instance" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db,openmrs >/dev/null 2>&1
    snapshot_env_files
    run env OPENHIM_PASSWORD="it's" "$BIN/openmrs-docker" "$NAME" add-service openhim
    assert_failure
    assert_output --partial "OPENHIM_PASSWORD contains a single quote or newline"
    [ ! -e "$(env_file_of "$NAME" openhim)" ]
    assert_env_files_unchanged
}

@test "each container gets its own service's variables, not every instance secret" {
    NAME="$(instance)"
    local dir
    OMRS_EXTRA_foo=bar OPENHIM_PASSWORD=Him-pw-1 "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db,openmrs,openhim >/dev/null 2>&1
    dir="$PIHX_HOME/$NAME"
    run stat -c %a "$dir/instance.env" "$dir/openmrs.env" "$dir/openmrs-db.env" "$dir/openhim.env"
    assert_output $'600\n600\n600\n600'
    run instance_compose_of "$NAME" config --format json
    assert_success
    local config=$output
    run jq -r '.services.openmrs.environment | keys[]' <<< "$config"
    assert_line OMRS_EXTRA_foo
    refute_line --regexp '^(OPENMRS_DB_ROOT_PASSWORD|OPENMRS_DB_OPT_.*|OPENHIM_PASSWORD)$'
    # openmrs-db's own variables (its defaults and openmrs-db.env), and no other service's
    run jq -r '.services["openmrs-db"].environment | keys[]' <<< "$config"
    assert_line OPENMRS_DB_OPT_character_set_server
    refute_line --regexp '^(OMRS_EXTRA_foo|OPENHIM_PASSWORD)$'
}

@test "an edit to a service's env file is what its container gets next, with nothing to regenerate" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
    echo "OPENMRS_DB_OPT_long_query_time='7'" >> "$(env_file_of "$NAME" openmrs-db)"
    run instance_compose_of "$NAME" config --format json
    assert_success
    run jq -r '.services["openmrs-db"].environment.OPENMRS_DB_OPT_long_query_time' <<< "$output"
    assert_output 7
}

@test "create writes one env file per service, instance.env and the tools link, and nothing else" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db,openmrs,openhim >/dev/null 2>&1
    run ls -A "$PIHX_HOME/$NAME"
    assert_output "$(printf '%s\n' instance.env openhim.env openmrs-db.env openmrs.env tools)"
    assert_equal "$(readlink "$PIHX_HOME/$NAME/tools")" "$REPO_ROOT"
}

@test "a value deleted from a service's env file falls back to its default" {
    NAME="$(instance)"
    local env
    OPENMRS_DB_MEMORY_LIMIT=3g "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
    env="$(env_file_of "$NAME" openmrs-db)"
    run grep -c "^OPENMRS_DB_MEMORY_LIMIT='3g'$" "$env"
    assert_output 1
    sed -i '/^OPENMRS_DB_MEMORY_LIMIT=/d' "$env"
    run "$BIN/openmrs-docker" "$NAME" status
    assert_success
    run instance_config "$NAME"
    assert_line OPENMRS_DB_MEMORY_LIMIT=2g
}

@test "create refuses a name Compose can't use as its project name, and creates nothing" {
    NAME="$(instance)"
    local bad
    for bad in "$NAME-Upper" "$NAME/sub" ".$NAME" "-$NAME"; do
        run "$BIN/openmrs-docker" "$bad" create
        assert_failure
        assert_output --partial "must be lowercase letters, digits, '-' and '_'"
        [ ! -e "$PIHX_HOME/$bad" ]
    done
}

@test "create never takes SERVICE_NAME from the environment: the instance's name is its project name" {
    NAME="$(instance)"
    SERVICE_NAME="$NAME-Upper" "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
    run grep -r '^SERVICE_NAME=' "$PIHX_HOME/$NAME"
    assert_output ''
    run "$BIN/openmrs-docker" "$NAME" status
    assert_success
    run "$BIN/openmrs-docker" "$NAME" destroy --force
    assert_success
    [ ! -e "$PIHX_HOME/$NAME" ]
}

@test "list shows only instance directories" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
    mkdir -p "${PIHX_HOME:?}/${NAME:?}-not-an-instance"
    run "$BIN/openmrs-docker" list
    assert_success
    assert_line --regexp "^$NAME +openmrs-db "
    refute_output --partial "$NAME-not-an-instance"
    rmdir "${PIHX_HOME:?}/${NAME:?}-not-an-instance"
}

@test "add-service leaves the instance unchanged when the service needs one it doesn't have" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db,openmrs >/dev/null 2>&1
    snapshot_env_files
    # the mediator requires openhim, which isn't part of the instance
    run "$BIN/openmrs-docker" "$NAME" add-service openhim-advapacs-mediator
    assert_failure
    assert_output --partial "openhim-advapacs-mediator requires openhim"
    [ ! -e "$(env_file_of "$NAME" openhim-advapacs-mediator)" ]
    assert_env_files_unchanged
    run "$BIN/openmrs-docker" "$NAME" status
    assert_success
}

@test "add-service openmrs names OPENMRS_IMAGE_NAME when it isn't set" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
    run env -u OPENMRS_IMAGE_NAME "$BIN/openmrs-docker" "$NAME" add-service openmrs
    assert_failure
    assert_output --partial "OPENMRS_IMAGE_NAME must be set"
    [ ! -e "$(env_file_of "$NAME" openmrs)" ]
}

@test "a command refuses options it doesn't take, and an unknown command is named" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
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
    assert [ -d "$PIHX_HOME/$NAME" ]
}

@test "sqlserver needs SQLSERVER_SA_PASSWORD: create and add-service refuse without it, changing nothing" {
    NAME="$(instance)"
    run env -u SQLSERVER_SA_PASSWORD "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db,sqlserver
    assert_failure
    assert_output --regexp 'SQLSERVER_SA_PASSWORD( is missing a value)?: must be set'
    assert [ ! -e "$PIHX_HOME/$NAME" ]
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
    snapshot_env_files
    run env -u SQLSERVER_SA_PASSWORD "$BIN/openmrs-docker" "$NAME" add-service sqlserver
    assert_failure
    assert_output --regexp 'SQLSERVER_SA_PASSWORD( is missing a value)?: must be set'
    assert [ ! -e "$(env_file_of "$NAME" sqlserver)" ]
    assert_env_files_unchanged
    SQLSERVER_SA_PASSWORD='Pw-1234x' run "$BIN/openmrs-docker" "$NAME" add-service sqlserver
    assert_success
    run grep -c "^SQLSERVER_SA_PASSWORD='Pw-1234x'$" "$(env_file_of "$NAME" sqlserver)"
    assert_output 1
}

@test "advapacs-gateway needs its region and access key: add-service refuses without them, changing nothing" {
    NAME="$(instance)"
    "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db >/dev/null 2>&1
    snapshot_env_files
    run env -u ADVAPACS_GATEWAY_REGION -u ADVAPACS_GATEWAY_ACCESS_KEY_ID -u ADVAPACS_GATEWAY_ACCESS_KEY_SECRET \
        "$BIN/openmrs-docker" "$NAME" add-service advapacs-gateway
    assert_failure
    # Compose names whichever required variable it reaches first.
    assert_output --regexp 'ADVAPACS_GATEWAY_(REGION|ACCESS_KEY_ID|ACCESS_KEY_SECRET)( is missing a value)?: must be set'
    assert [ ! -e "$(env_file_of "$NAME" advapacs-gateway)" ]
    assert_env_files_unchanged
    ADVAPACS_GATEWAY_REGION=usa1 ADVAPACS_GATEWAY_ACCESS_KEY_ID=key-id ADVAPACS_GATEWAY_ACCESS_KEY_SECRET=key-secret \
        run "$BIN/openmrs-docker" "$NAME" add-service advapacs-gateway
    assert_success
    run grep -E '^ADVAPACS_GATEWAY_(REGION|ACCESS_KEY_ID|ACCESS_KEY_SECRET)=' "$(env_file_of "$NAME" advapacs-gateway)"
    assert_line "ADVAPACS_GATEWAY_REGION='usa1'"
    assert_line "ADVAPACS_GATEWAY_ACCESS_KEY_ID='key-id'"
    assert_line "ADVAPACS_GATEWAY_ACCESS_KEY_SECRET='key-secret'"
}

@test "create writes TZ to instance.env, and OPENMRS_DISTRO_DIR to openmrs.env" {
    NAME="$(instance)"
    local env
    TZ=Africa/Maseru OPENMRS_DISTRO_DIR=/src/distro "$BIN/openmrs-docker" "$NAME" create >/dev/null 2>&1
    env="$(env_file_of "$NAME" instance)"
    run cat "$env"
    assert_output "TZ='Africa/Maseru'"
    run grep '^OPENMRS_DISTRO_DIR=' "$(env_file_of "$NAME" openmrs)"
    assert_output "OPENMRS_DISTRO_DIR='/src/distro'"
    # deleted, TZ is its default again
    sed -i '/^TZ=/d' "$env"
    run env -u TZ "$BIN/openmrs-docker" "$NAME" status
    assert_success
    run env -u TZ "$BIN/pihx" "$NAME" config
    assert_line "TZ=UTC"
}

@test "adding petl declares its MySQL account and SQL Server login from its own variables" {
    NAME="$(instance)"
    PETL_MYSQL_PASSWORD='My-pw-1' PETL_SQLSERVER_PASSWORD='Sql-pw-1' SQLSERVER_SA_PASSWORD='Sa-pw-1' \
        create_instance "$NAME" --services=openmrs-db,petl,sqlserver
    run cat "$(env_file_of "$NAME" petl)"
    assert_line "PETL_MYSQL_PASSWORD='My-pw-1'"
    assert_line "PETL_SQLSERVER_PASSWORD='Sql-pw-1'"
    run instance_compose_of "$NAME" config --format json
    assert_success
    local config=$output
    run jq -r '.services["openmrs-db-accounts"].environment | to_entries[] | select(.key | startswith("OPENMRS_DB_ACCOUNT_PETL_")) | "\(.key)=\(.value)"' <<< "$config"
    assert_line "OPENMRS_DB_ACCOUNT_PETL_USER=petl"
    assert_line "OPENMRS_DB_ACCOUNT_PETL_PASSWORD=My-pw-1"
    assert_line "OPENMRS_DB_ACCOUNT_PETL_GRANTS=ALL ON *.*"
    run jq -r '.services["sqlserver-setup"].environment | to_entries[] | select(.key | startswith("SQLSERVER_LOGIN_PETL_")) | "\(.key)=\(.value)"' <<< "$config"
    assert_line "SQLSERVER_LOGIN_PETL_USER=petl"
    assert_line "SQLSERVER_LOGIN_PETL_PASSWORD=Sql-pw-1"
    assert_line "SQLSERVER_LOGIN_PETL_DATABASES=openmrs_reporting"
}

@test "petl's MySQL options name the time zone, left for PETL to resolve as its JVM's" {
    NAME="$(instance)"
    PETL_MYSQL_PASSWORD='My-pw-1' create_instance "$NAME" --services=openmrs-db,petl
    run instance_compose_of "$NAME" --profile '*' config --format json
    assert_success
    run jq -r '.services.petl.environment.PETL_MYSQL_OPTIONS' <<< "$output"
    # config prints a literal $ as $$
    assert_output 'autoReconnect=true&sessionVariables=default_storage_engine%3DInnoDB&useUnicode=true&characterEncoding=UTF-8&useLegacyDatetimeCode=false&serverTimezone=$${user.timezone}'
}

@test "petl needs PETL_MYSQL_PASSWORD" {
    NAME="$(instance)"
    run env -u PETL_MYSQL_PASSWORD PETL_SQLSERVER_PASSWORD=x "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db,petl
    assert_failure
    assert_output --regexp 'PETL_MYSQL_PASSWORD( is missing a value)?: must be set'
}

@test "petl doesn't need PETL_SQLSERVER_PASSWORD (an ETL writing only to MySQL)" {
    NAME="$(instance)"
    run env -u PETL_SQLSERVER_PASSWORD PETL_MYSQL_PASSWORD=My-pw-1 "$BIN/openmrs-docker" "$NAME" create --services=openmrs-db,petl
    assert_success
    run instance_config "$NAME"
    assert_line "PETL_SQLSERVER_PASSWORD="
}

@test "account declarations in openmrs-db.env reach openmrs-db-accounts, and petl's reach only it, not openmrs-db" {
    NAME="$(instance)"
    PETL_MYSQL_PASSWORD='My-pw-1' create_instance "$NAME" --services=openmrs-db,petl
    printf "OPENMRS_DB_ACCOUNT_RPT_USER='reports'\nOPENMRS_DB_ACCOUNT_RPT_PASSWORD='Pw-1'\n" >> "$(env_file_of "$NAME" openmrs-db)"
    run instance_compose_of "$NAME" config --format json
    assert_success
    local config=$output
    run jq -r '.services["openmrs-db-accounts"].environment | keys[] | select(startswith("OPENMRS_DB_ACCOUNT_"))' <<< "$config"
    assert_line OPENMRS_DB_ACCOUNT_RPT_USER
    assert_line OPENMRS_DB_ACCOUNT_PETL_PASSWORD
    run jq -r '.services["openmrs-db"].environment | keys[] | select(startswith("OPENMRS_DB_ACCOUNT_PETL_"))' <<< "$config"
    assert_output ''
}

@test "petl works without sqlserver: add-service petl, and remove-service sqlserver from an instance with petl" {
    NAME="$(instance)"
    create_instance "$NAME" --services=openmrs-db
    run env PETL_MYSQL_PASSWORD=My-pw-1 PETL_SQLSERVER_PASSWORD=Sql-pw-1 PETL_SQLSERVER_HOST=reports.example.org \
        "$BIN/openmrs-docker" "$NAME" add-service petl
    assert_success
    destroy_instance "$NAME"
    PETL_MYSQL_PASSWORD=My-pw-1 PETL_SQLSERVER_PASSWORD=Sql-pw-1 SQLSERVER_SA_PASSWORD=Sa-pw-1 \
        create_instance "$NAME" --services=openmrs-db,petl,sqlserver
    run "$BIN/openmrs-docker" "$NAME" remove-service sqlserver
    assert_success
}
