#!/usr/bin/env bats
# sqlserver-setup configures SQL Server and makes sure the declared databases and logins exist, on
# every start and before services that depend on it.

load ../helpers

# One SQL Server at a time from this file: each takes up to 3 GB, and several at once on a CI runner
# (or a laptop) leave one unhealthy.
setup_file() { export BATS_NO_PARALLELIZE_WITHIN_FILE=true; }

SA='Sa-Placeholder-1'
# Needs quoting in T-SQL and the shell (a single quote can't be in an env file); meets SQL Server's
# complexity rules.
PW='pa$s "w;d`x-1A'

setup() {
    NAME="$(instance)"
    SQLSERVER_SA_PASSWORD="$SA" SQLSERVER_PUBLISHED_PORT=0 SERVICES=sqlserver create_instance "$NAME"
    ENV="$OPENMRS_DOCKER_HOME/$NAME/env"
}
teardown() { destroy_instance "$NAME"; common_teardown; }

# Starts the instance and waits for sqlserver-setup to exit; prints its exit code.
start_and_wait_for_setup() {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1 || true
    docker wait "$NAME-sqlserver-setup"
}

sqlcmd_as() { # <login> <password> <query>
    docker exec -e SQLCMDPASSWORD="$2" "$NAME-sqlserver" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U "$1" -h -1 -W -Q "SET NOCOUNT ON; $3"
}

@test "start applies the server settings, creates the databases and a login with a password needing quoting" {
    printf "SQLSERVER_DATABASES='openmrs_ces_ci'\nSQLSERVER_LOGIN_PETL_USER='petl'\nSQLSERVER_LOGIN_PETL_PASSWORD='%s'\nSQLSERVER_LOGIN_PETL_DATABASES='openmrs_ces_ci other_db'\n" "$PW" >> "$ENV"
    record_docker_argv
    run start_and_wait_for_setup
    assert_output 0
    assert_not_in_docker_argv "$PW"
    run docker logs "$NAME-sqlserver-setup"
    assert_output --partial 'Server settings applied'
    assert_output --partial 'Login petl ready'
    assert_output --partial 'petl is db_owner in other_db'
    run sqlcmd_as petl "$PW" "SELECT name FROM sys.databases WHERE name IN ('openmrs_ces_ci','other_db') ORDER BY name"
    assert_output $'openmrs_ces_ci\nother_db'
    run sqlcmd_as sa "$SA" "SELECT recovery_model_desc FROM sys.databases WHERE name = 'openmrs_ces_ci'"
    assert_output SIMPLE
    # At least SQLSERVER_TEMPDB_FILES (4): the image itself may already create one per CPU, up to 8.
    run sqlcmd_as sa "$SA" "SELECT COUNT(*) FROM tempdb.sys.database_files WHERE type = 0 AND name IN ('tempdev','tempdev2','tempdev3','tempdev4')"
    assert_output 4
}

@test "a rerun syncs a login's password; a bad declaration changes nothing" {
    printf "SQLSERVER_LOGIN_PETL_USER='petl'\nSQLSERVER_LOGIN_PETL_PASSWORD='First-pw-1'\nSQLSERVER_LOGIN_PETL_DATABASES='db1'\n" >> "$ENV"
    run start_and_wait_for_setup
    assert_output 0
    sed -i "s/^SQLSERVER_LOGIN_PETL_PASSWORD=.*/SQLSERVER_LOGIN_PETL_PASSWORD='Second-pw-2'/" "$ENV"
    printf "SQLSERVER_LOGIN_BAD_USER='bad]login'\nSQLSERVER_LOGIN_BAD_PASSWORD='x'\nSQLSERVER_LOGIN_BAD_DATABASES='db2'\n" >> "$ENV"
    run start_and_wait_for_setup
    assert_output 1
    run docker logs "$NAME-sqlserver-setup"
    assert_output --partial 'SQLSERVER_LOGIN_BAD_USER'
    assert_output --partial 'nothing was changed'
    run sqlcmd_as petl First-pw-1 "SELECT 1"
    assert_output 1
    sed -i '/^SQLSERVER_LOGIN_BAD_/d' "$ENV"
    run start_and_wait_for_setup
    assert_output 0
    run sqlcmd_as petl Second-pw-2 "SELECT 1"
    assert_output 1
}

@test "a password containing the login name is refused, naming it" {
    printf "SQLSERVER_LOGIN_PETL_USER='petl'\nSQLSERVER_LOGIN_PETL_PASSWORD='Petl-pw-1'\nSQLSERVER_LOGIN_PETL_DATABASES='db1'\n" >> "$ENV"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_failure
    assert_output --partial "sqlserver-setup failed"
    assert_output --partial "SQLSERVER_LOGIN_PETL_PASSWORD can't contain the login name"
}

@test "run-service stops before the service runs when a setup fails" {
    destroy_instance "$NAME"
    NAME="$(instance)-petl"
    PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=My-pw-1 PETL_SQLSERVER_PASSWORD=Sql-pw-1 \
        SQLSERVER_SA_PASSWORD="$SA" SQLSERVER_PUBLISHED_PORT=0 SERVICES=openmrs-db,petl,sqlserver create_instance "$NAME"
    sed -i "s/^SQLSERVER_LOGIN_PETL_USER=.*/SQLSERVER_LOGIN_PETL_USER='bad]login'/" "$OPENMRS_DOCKER_HOME/$NAME/env"
    run "$BIN/openmrs-docker" "$NAME" run-service petl sh -c 'echo PETL-RAN'
    assert_failure
    assert_output --partial "sqlserver-setup failed"
    refute_output --partial "PETL-RAN"
}

@test "a password with sqlcmd's \$(variable) syntax is kept literally" {
    printf "SQLSERVER_LOGIN_RPT_USER='reports'\nSQLSERVER_LOGIN_RPT_PASSWORD='Ab1-\$(SQLCMDUSER)z'\nSQLSERVER_LOGIN_RPT_DATABASES='db1'\n" >> "$ENV"
    run start_and_wait_for_setup
    assert_output 0
    run sqlcmd_as reports 'Ab1-$(SQLCMDUSER)z' "SELECT 1"
    assert_output 1
}

@test "a declared sa login is refused, naming it" {
    printf "SQLSERVER_LOGIN_ADMIN_USER='sa'\nSQLSERVER_LOGIN_ADMIN_PASSWORD='Other-pw-9'\nSQLSERVER_LOGIN_ADMIN_DATABASES='db1'\n" >> "$ENV"
    run "$BIN/openmrs-docker" "$NAME" start
    assert_failure
    assert_output --partial "SQLSERVER_LOGIN_ADMIN_USER can't be sa"
}
