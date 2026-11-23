#!/usr/bin/env bats
# pihx <instance> dhis2 upgrade, with real DHIS2 releases from the real versions list, on an empty
# dhis2-db (never real data). Each test downloads the 2.43.2.1 WAR (about 345 MB), the first also
# 2.42.7.1's, and waits for DHIS2 to build or migrate its schema.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    DIR="$PIHX_HOME/$NAME"
    export DHIS2_DB_PASSWORD='Placeholder-1' DHIS2_DB_PORT=0 DHIS2_HTTP_PORT=0
}
teardown() {
    remove_test_instance "$NAME"
    common_teardown
}

# The Tomcat tag the versions list gives <version>.
tag_of() { # <version>
    awk -v v="$1" '!/^#/ && $1 == v { print $2 }' "$REPO_ROOT/services/dhis2/scripts/versions"
}
# A value as dhis2.env holds it, unquoted.
env_value() { # <name>
    sed -n "s/^$1='\(.*\)'$/\1/p" "$DIR/dhis2.env"
}
in_home() { # <command...>, in the DHIS2 home volume
    docker run --rm -v "${NAME}_dhis2-data:/home" "$ALPINE_IMAGE" "$@"
}
psql_value() { # <query>
    docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc "$1"
}

@test "one step: 2.42.7.1 to 2.43.2.1 sets the version and tag, logs the step, and DHIS2 comes up" {
    DHIS2_VERSION=2.42.7.1 DHIS2_TOMCAT_TAG="$(tag_of 2.42.7.1)" \
        "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    run "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2" --timeout=1800
    assert_success

    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_success
    assert_output --partial "DHIS2 2.42.7.1 -> 2.43.2.1"
    assert_line --index -1 "$NAME is on DHIS2 2.43.2.1."
    assert_equal "$(env_value DHIS2_VERSION)" 2.43.2.1
    assert_equal "$(env_value DHIS2_TOMCAT_TAG)" "$(tag_of 2.43.2.1)"
    assert [ ! -e "$DIR/dhis2-upgrade.pending" ]
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp '^[0-9-]+T[0-9:]+Z 2\.42\.7\.1 -> 2\.43\.2\.1 fixes=\[\] [0-9]+s ok$'
    echo "# step: $output" >&3
    run in_home cat /home/.dhis2-version
    assert_output 2.43.2.1
    run docker inspect -f '{{.State.Health.Status}} {{.Config.Image}}' "$NAME-dhis2"
    assert_output "healthy tomcat:$(tag_of 2.43.2.1)"

    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_success
    assert_output --partial 'nothing to do'
}

@test "a step that doesn't come up keeps .pending, and the next run retries that version: its fixes only when chosen" {
    # A fix for 2.43.2.1, in a copy of the tools, so the repo's known-fixes stay as they are.
    local tools="$BATS_TEST_TMPDIR/tools"
    mkdir "$tools"
    (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$tools"
    mkdir -p "$tools/services/dhis2/known-fixes/2.43.2.1"
    echo 'CREATE TABLE IF NOT EXISTS upgrade_test_fix (n int); INSERT INTO upgrade_test_fix VALUES (1);' \
        > "$tools/services/dhis2/known-fixes/2.43.2.1/10-test-fix.sql"
    # No containers, and only the database volume, as initialize leaves a restored instance (with an
    # empty database here): the step starts dhis2-db, and the start makes the other volumes.
    DHIS2_VERSION=2.42.7.1 DHIS2_TOMCAT_TAG="$(tag_of 2.42.7.1)" \
        "$tools/bin/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    docker volume create --label "pihx.instance=$NAME" "${NAME}_dhis2-db-data" >/dev/null

    # A second isn't long enough for DHIS2 to come up: the wait fails, DHIS2 itself is fine.
    set_env_value "$NAME" dhis2 DHIS2_UPGRADE_STEP_TIMEOUT 1
    run "$BIN/pihx" "$NAME" dhis2 upgrade --with-fix=2.43.2.1/10-test-fix.sql
    assert_failure
    assert_output --partial "DHIS2 2.43.2.1 didn't come up."
    assert_equal "$(cat "$DIR/dhis2-upgrade.pending")" 2.43.2.1
    assert_equal "$(env_value DHIS2_VERSION)" 2.43.2.1
    assert_equal "$(psql_value 'SELECT count(*) FROM upgrade_test_fix')" 1
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp ' 2\.42\.7\.1 -> 2\.43\.2\.1 fixes=\[10-test-fix\.sql\] [0-9]+s failed$'

    # Retried, not skipped (2.43.2.1 is the last version: a skip would say "nothing to do"), and
    # without the fix this time.
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_failure
    assert_output --partial "DHIS2 2.43.2.1 didn't come up last time: retrying it"
    assert_output --partial "DHIS2 2.43.2.1 didn't come up."
    assert_equal "$(psql_value 'SELECT count(*) FROM upgrade_test_fix')" 1
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp ' 2\.42\.7\.1 -> 2\.43\.2\.1 fixes=\[\] [0-9]+s failed$'
    assert_equal "$(cat "$DIR/dhis2-upgrade.pending")" 2.43.2.1

    # With time to come up, the retry completes.
    sed -i '/^DHIS2_UPGRADE_STEP_TIMEOUT=/d' "$DIR/dhis2.env"
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_success
    assert_line --index -1 "$NAME is on DHIS2 2.43.2.1."
    assert [ ! -e "$DIR/dhis2-upgrade.pending" ]
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp ' 2\.42\.7\.1 -> 2\.43\.2\.1 fixes=\[\] [0-9]+s ok$'
}

@test "the known fixes are idempotent and change only what they should, on tables shaped as they expect" {
    # dhis2-db's image on its own: the fixes need only PostgreSQL.
    local db; db="$(res db)"
    docker run -d --name "$db" -e POSTGRES_USER=dhis -e POSTGRES_DB=dhis -e POSTGRES_PASSWORD=Placeholder-1 \
        --health-cmd "pg_isready -h 127.0.0.1 -U dhis -d dhis" --health-interval 1s postgis/postgis:16-3.5 >/dev/null
    run "$UTILS/wait-for-healthy.sh" --container="$db" --timeout=300
    assert_success
    docker exec -i "$db" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE userrole (userroleid int PRIMARY KEY);
CREATE TABLE program_userroles (programid int, userroleid int);
INSERT INTO userrole VALUES (1);
INSERT INTO program_userroles VALUES (1, 1), (1, 2);
CREATE TABLE dataelementoperand (dataelementoperandid int PRIMARY KEY);
CREATE TABLE sectiongreyedfields (dataelementoperandid int);
CREATE TABLE datasetoperands (dataelementoperandid int);
CREATE TABLE program_attribute_group (programtrackedentityattributegroupid int);
CREATE TABLE trackedentityaudit (trackedentityauditid int, visitor varchar(255), accessedmodule varchar(255));
INSERT INTO trackedentityaudit VALUES (1, 'admin', 'tracker');
CREATE TABLE trackedentityinstanceaudit (trackedentityinstanceauditid int);
SQL
    local f
    for f in "$REPO_ROOT"/services/dhis2/known-fixes/*/*.sql; do
        run bash -c 'for i in 1 2; do docker exec -i "$1" psql -X -1 -U dhis -d dhis -q -v ON_ERROR_STOP=1 < "$2" || exit 1; done' \
            _ "$db" "$f"
        assert_success
    done
    # The orphaned program_userroles row went; the one for an existing role stayed.
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc 'SELECT userroleid FROM program_userroles')" 1
    # The legacy trackedentityaudit is kept, renamed.
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc 'SELECT visitor FROM trackedentityaudit_legacy')" admin
}
