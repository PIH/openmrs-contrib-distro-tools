#!/usr/bin/env bats
# pihx <instance> dhis2 reset-password, on dhis2-db's image alone with tables shaped as DHIS2 2.30's
# (`users`) and 2.41's and later (`userinfo`): no DHIS2. dhis2.bats checks a real login on 2.43.

load ../helpers

PW="pa'ss\$w\\rd 1"

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    export DHIS2_DB_PASSWORD='Placeholder-1'
    DHIS2_VERSION=2.30 DHIS2_TOMCAT_TAG=9-jdk8-temurin-noble \
        "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
}
teardown() {
    docker rm -f "$NAME-dhis2-db" >/dev/null 2>&1 || true
    remove_test_instance "$NAME"
    common_teardown
}

# dhis2-db's image as the instance's dhis2-db container, with <sql> run in it.
start_db() { # <sql>
    docker run -d --name "$NAME-dhis2-db" -e POSTGRES_USER=dhis -e POSTGRES_DB=dhis -e POSTGRES_PASSWORD=Placeholder-1 \
        --health-cmd "pg_isready -h 127.0.0.1 -U dhis -d dhis" --health-interval 1s postgis/postgis:16-3.5 >/dev/null
    "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2-db" --timeout=300 >/dev/null
    docker exec -i "$NAME-dhis2-db" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 <<< "$1"
}
psql_value() { # <query>
    docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc "$1"
}
# Whether <password> matches <table>'s hash for <user>, checked with pgcrypto in a rolled-back transaction.
matches() { # <table> <user> <password>
    docker exec -i -e P="$3" "$NAME-dhis2-db" psql -U dhis -d dhis -qtA -v ON_ERROR_STOP=1 <<SQL
\getenv p P
BEGIN;
CREATE SCHEMA pihx_test_crypto;
CREATE EXTENSION pgcrypto WITH SCHEMA pihx_test_crypto;
SELECT pihx_test_crypto.crypt(:'p', password) = password FROM $1 WHERE username = '$2';
ROLLBACK;
SQL
}

USERS_230="CREATE TABLE userinfo (userinfoid int, surname text);
CREATE FUNCTION gen_random_uuid() RETURNS uuid AS 'SELECT NULL::uuid' LANGUAGE sql;  -- as 2.43 has, which a pgcrypto in public would clash with
CREATE TABLE users (userid int, username varchar(255), password varchar(60), externalauth boolean,
    passwordlastupdated timestamp, disabled boolean, secret text NOT NULL, twofa boolean);
INSERT INTO users VALUES (1, 'admin', 'old', true, NULL, true, 'S1', true),
                         (2, 'other', 'old', true, NULL, true, 'S2', true);"

@test "on a 2.30 schema: sets a bcrypt hash of the password in users, and the account can log in; others untouched" {
    start_db "$USERS_230"
    run bash -c 'printf "%s\n" "$1" | "$2" "$3" dhis2 reset-password' _ "$PW" "$BIN/pihx" "$NAME"
    assert_success
    assert_output --partial "Password set for admin."
    refute_output --partial "$PW"
    assert_equal "$(matches users admin "$PW")" t
    run psql_value "SELECT left(password, 7), externalauth, disabled, twofa, secret, passwordlastupdated IS NOT NULL FROM users WHERE username = 'admin'"
    assert_output '$2a$10$|f|f|f|S1|t'
    run psql_value "SELECT password, externalauth, disabled, twofa FROM users WHERE username = 'other'"
    assert_output 'old|t|t|t'
    # The hash came from pgcrypto, which isn't left installed.
    run psql_value "SELECT count(*) FROM pg_extension WHERE extname = 'pgcrypto'"
    assert_output 0
    run psql_value "SELECT count(*) FROM pg_namespace WHERE nspname = 'pihx_reset_password'"
    assert_output 0
}

@test "on a 2.41+ schema: finds the user in userinfo and turns off its two-factor type" {
    start_db "CREATE TABLE userinfo (userinfoid int, username varchar(255), password varchar(60), externalauth boolean,
    passwordlastupdated timestamp, disabled boolean, secret text, twofactortype varchar(50));
INSERT INTO userinfo VALUES (1, 'trainer', 'old', false, NULL, true, 'S1', 'TOTP_ENABLED');"
    run bash -c 'printf "%s\n" "$1" | "$2" "$3" dhis2 reset-password trainer' _ "$PW" "$BIN/pihx" "$NAME"
    assert_success
    assert_equal "$(matches userinfo trainer "$PW")" t
    run psql_value "SELECT disabled, twofactortype FROM userinfo WHERE username = 'trainer'"
    assert_output 'f|NOT_ENABLED'
}

@test "refuses an instance with no database, a database with no DHIS2 users, an unknown user, an empty password and extra arguments, changing nothing" {
    # Never started: no database volume to start dhis2-db on.
    run bash -c 'printf "x\n" | "$1" "$2" dhis2 reset-password' _ "$BIN/pihx" "$NAME"
    assert_failure
    assert_output --partial "an instance never started or initialized has no database"

    start_db "SELECT 1;"
    run bash -c 'printf "x\n" | "$1" "$2" dhis2 reset-password' _ "$BIN/pihx" "$NAME"
    assert_failure
    assert_output --partial "no users or userinfo table with username and password"

    docker exec -i "$NAME-dhis2-db" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 <<< "$USERS_230"
    run bash -c 'printf "x\n" | "$1" "$2" dhis2 reset-password nobody' _ "$BIN/pihx" "$NAME"
    assert_failure
    assert_output --partial "no DHIS2 user named nobody"
    run bash -c 'printf "\n" | "$1" "$2" dhis2 reset-password' _ "$BIN/pihx" "$NAME"
    assert_failure
    assert_output --partial "the password is empty"
    run "$BIN/pihx" "$NAME" dhis2 reset-password a b
    assert_failure
    assert_output --partial "usage: pihx $NAME dhis2 reset-password [<username>]"
    run psql_value "SELECT password FROM users WHERE username = 'admin'"
    assert_output old
}
