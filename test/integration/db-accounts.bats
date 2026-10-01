#!/usr/bin/env bats
# openmrs-db-accounts makes sure the accounts declared as OPENMRS_DB_ACCOUNT_<ID>_* exist, on every
# start and before services that depend on it.

load ../helpers

# Needs quoting in SQL and the shell; a single quote can't be in an env file at all.
PW='pa$s "w;d`x'

teardown() { destroy_instance "$NAME"; common_teardown; }

new_instance() { # [image name] [image tag]
    NAME="$(instance)"
    OPENMRS_DB_IMAGE_NAME="${1:-mysql}" OPENMRS_DB_IMAGE_TAG="${2:-5.6}" SERVICES=openmrs-db create_instance "$NAME"
    ENV="$OPENMRS_DOCKER_HOME/$NAME/env"
}

declare_account() { # <id> <user> <password> <grants> [databases]
    printf "OPENMRS_DB_ACCOUNT_%s_USER='%s'\nOPENMRS_DB_ACCOUNT_%s_PASSWORD='%s'\nOPENMRS_DB_ACCOUNT_%s_GRANTS='%s'\nOPENMRS_DB_ACCOUNT_%s_DATABASES='%s'\n" \
        "$1" "$2" "$1" "$3" "$1" "$4" "$1" "${5:-}" >> "$ENV"
}

# Starts the instance and waits for openmrs-db-accounts to exit; prints its exit code.
start_and_wait_for_accounts() {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1 || true
    docker wait "$NAME-openmrs-db-accounts"
}

db_as() { # <user> <password> <sql>: over TCP, as a service in the instance would
    docker exec -e MYSQL_PWD="$2" "$NAME-openmrs-db" sh -c \
        '"$(command -v mysql || command -v mariadb)" -h127.0.0.1 -u"$0" -N -e "$1"' "$1" "$3"
}

assert_account_created() {
    declare_account PETL petl "$PW" 'ALL ON *.*' 'openmrs_warehouse'
    record_docker_argv
    run start_and_wait_for_accounts
    assert_output 0
    assert_not_in_docker_argv "$PW"
    run docker logs "$NAME-openmrs-db-accounts"
    assert_output --partial 'Created petl@%'
    assert_output --partial 'Database openmrs_warehouse ready'
    run db_as petl "$PW" 'SHOW DATABASES LIKE "openmrs_warehouse"'
    assert_output openmrs_warehouse
}

@test "start creates a declared account, its databases and grants, with a password needing quoting (MySQL 5.6)" {
    new_instance
    assert_account_created
}

@test "the same on MySQL 8.0" {
    new_instance mysql 8.0
    assert_account_created
}

@test "the same on MariaDB 11" {
    new_instance mariadb 11.4
    assert_account_created
}

@test "a rerun sets the password to the one now in env, and leaves host-specific and undeclared accounts alone" {
    new_instance
    declare_account PETL petl "$PW" 'ALL ON *.*'
    run start_and_wait_for_accounts
    assert_output 0
    mysql_exec "$NAME-openmrs-db" openmrs "CREATE USER 'petl'@'127.0.0.1' IDENTIFIED BY 'legacy'; CREATE USER 'reports'@'%' IDENTIFIED BY 'keep';"
    sed -i "s/^OPENMRS_DB_ACCOUNT_PETL_PASSWORD=.*/OPENMRS_DB_ACCOUNT_PETL_PASSWORD='n3w-pw'/" "$ENV"
    run start_and_wait_for_accounts
    assert_output 0
    run docker logs "$NAME-openmrs-db-accounts"
    assert_output --partial 'Set the password of petl@%'
    # from another container, so it's petl@'%' (127.0.0.1 inside openmrs-db would match the legacy account)
    run docker run --rm --network "${NAME}_default" -e MYSQL_PWD=n3w-pw mysql:5.6 mysql -h openmrs-db -upetl -N -e 'SELECT 1'
    assert_output 1
    run mysql_exec "$NAME-openmrs-db" openmrs "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE user IN ('petl','reports') ORDER BY 1"
    assert_output $'petl@%\npetl@127.0.0.1\nreports@%'
}

@test "a bad declaration fails the run, naming it, and changes nothing" {
    new_instance
    declare_account PETL petl "$PW" 'ALL ON *.*' 'ok_db'
    declare_account BAD 'bad user' x 'DROP DATABASE openmrs'
    run start_and_wait_for_accounts
    assert_output 1
    run docker logs "$NAME-openmrs-db-accounts"
    assert_output --partial "OPENMRS_DB_ACCOUNT_BAD_USER"
    assert_output --partial "OPENMRS_DB_ACCOUNT_BAD_GRANTS"
    assert_output --partial "nothing was changed"
    run mysql_exec "$NAME-openmrs-db" openmrs "SELECT COUNT(*) FROM mysql.user WHERE user='petl'"
    assert_output 0
    run mysql_exec "$NAME-openmrs-db" openmrs "SHOW DATABASES LIKE 'ok_db'"
    assert_output ''
}

@test "no declarations: it does nothing and succeeds" {
    new_instance
    run start_and_wait_for_accounts
    assert_output 0
    run docker logs "$NAME-openmrs-db-accounts"
    assert_output --partial 'No OPENMRS_DB_ACCOUNT_* accounts declared'
}

@test "start fails, naming openmrs-db-accounts, when the account setup fails" {
    new_instance
    declare_account BAD 'bad user' x 'ALL ON *.*'
    run "$BIN/openmrs-docker" "$NAME" start
    assert_failure
    assert_output --partial "openmrs-db-accounts failed"
    assert_output --partial "OPENMRS_DB_ACCOUNT_BAD_USER"
}

@test "changing an account's password doesn't recreate openmrs-db" {
    new_instance
    declare_account RPT reports "$PW" 'SELECT ON openmrs.*'
    run start_and_wait_for_accounts
    assert_output 0
    local before
    before=$(docker inspect -f '{{.Id}}' "$NAME-openmrs-db")
    sed -i "s/^OPENMRS_DB_ACCOUNT_RPT_PASSWORD=.*/OPENMRS_DB_ACCOUNT_RPT_PASSWORD='n3w-pw'/" "$ENV"
    run start_and_wait_for_accounts
    assert_output 0
    assert_equal "$(docker inspect -f '{{.Id}}' "$NAME-openmrs-db")" "$before"
}
