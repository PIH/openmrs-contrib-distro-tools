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

# A copy of the tools in <dir>, with a fix for 2.43.2.1 that records each run, so the repo's
# known-fixes stay as they are.
tools_with_test_fix() { # <dir>
    mkdir "$1"
    (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$1"
    mkdir -p "$1/services/dhis2/known-fixes/2.43.2.1"
    echo 'CREATE TABLE IF NOT EXISTS upgrade_test_fix (n int); INSERT INTO upgrade_test_fix VALUES (1);' \
        > "$1/services/dhis2/known-fixes/2.43.2.1/10-test-fix.sql"
}

# No containers, and only the database volume, as initialize leaves a restored instance (with an
# empty database here): the step starts dhis2-db, and the start makes the other volumes.
create_restored() { # <tools dir>
    DHIS2_VERSION=2.42.7.1 DHIS2_TOMCAT_TAG="$(tag_of 2.42.7.1)" \
        "$1/bin/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    docker volume create --label "pihx.instance=$NAME" "${NAME}_dhis2-db-data" >/dev/null
}

@test "a step that times out while DHIS2 is still starting says so, and a run then refuses to stop it, healthcheck starting or unhealthy; once it's up, the next run retries that version, its fixes only when chosen, and its wait outlasts unhealthy" {
    tools_with_test_fix "$BATS_TEST_TMPDIR/tools"
    create_restored "$BATS_TEST_TMPDIR/tools"
    # A test-only override (the service's 2h start_period stays as it is): DHIS2 reports unhealthy
    # about 13 s after it starts, long before its first start on an empty database is done, as a
    # long migration does after 2h.
    cat > "$DIR/dhis2.override.yaml" <<'YAML'
services:
  dhis2:
    healthcheck:
      start_period: 10s
      interval: 3s
      retries: 1
YAML

    # A second isn't long enough for DHIS2 to come up: the wait times out, DHIS2 carries on.
    set_env_value "$NAME" dhis2 DHIS2_UPGRADE_STEP_TIMEOUT 1
    run "$BIN/pihx" "$NAME" dhis2 upgrade --with-fix=2.43.2.1/10-test-fix.sql
    assert_failure
    assert_output --partial "DHIS2 2.43.2.1 hasn't come up within 1s, but is still starting: its migrations may still be running."
    refute_output --partial "didn't come up."
    assert_equal "$(cat "$DIR/dhis2-upgrade.pending")" 2.43.2.1
    assert_equal "$(env_value DHIS2_VERSION)" 2.43.2.1
    assert_equal "$(psql_value 'SELECT count(*) FROM upgrade_test_fix')" 1
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp ' 2\.42\.7\.1 -> 2\.43\.2\.1 fixes=\[10-test-fix\.sql\] [0-9]+s failed$'

    # Run again at once, its healthcheck still starting: refused, DHIS2 left running, nothing logged.
    local started logged
    started=$(docker inspect -f '{{.State.StartedAt}}' "$NAME-dhis2")
    logged=$(wc -l < "$DIR/dhis2-upgrade.log")
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_failure
    assert_output --partial "$NAME-dhis2 is still starting on DHIS2 2.43.2.1"
    assert_equal "$(docker inspect -f '{{.State.Running}} {{.State.StartedAt}}' "$NAME-dhis2")" "true $started"

    # Past its start_period, still building its schema: unhealthy, and still refused.
    local i
    for i in $(seq 60); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME-dhis2")" != unhealthy ] || break
        sleep 1
    done
    assert_equal "$(docker inspect -f '{{.State.Running}} {{.State.Health.Status}}' "$NAME-dhis2")" "true unhealthy"
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_failure
    assert_output --partial "$NAME-dhis2 is still starting on DHIS2 2.43.2.1"
    assert_equal "$(docker inspect -f '{{.State.Running}} {{.State.StartedAt}}' "$NAME-dhis2")" "true $started"
    assert_equal "$(wc -l < "$DIR/dhis2-upgrade.log")" "$logged"
    assert_equal "$(cat "$DIR/dhis2-upgrade.pending")" 2.43.2.1

    # Once it's up, the version is retried, not skipped (2.43.2.1 is the last version: a skip would
    # say "nothing to do"), and without the fix this time. DHIS2's restart takes longer than the
    # override's 13 s, so the step's wait sees unhealthy and waits on.
    run "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2" --timeout=1800
    assert_success
    sed -i '/^DHIS2_UPGRADE_STEP_TIMEOUT=/d' "$DIR/dhis2.env"
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_success
    assert_output --partial "DHIS2 2.43.2.1 didn't come up last time: retrying it"
    assert_line --index -1 "$NAME is on DHIS2 2.43.2.1."
    assert_equal "$(psql_value 'SELECT count(*) FROM upgrade_test_fix')" 1
    assert [ ! -e "$DIR/dhis2-upgrade.pending" ]
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp ' 2\.42\.7\.1 -> 2\.43\.2\.1 fixes=\[\] [0-9]+s ok$'
    local seconds
    seconds=$(tail -n 1 "$DIR/dhis2-upgrade.log" | sed 's/.* \([0-9]*\)s ok$/\1/')
    echo "# retry step: ${seconds}s" >&3
    assert [ "$seconds" -gt 20 ]
}

@test "a step whose setup fails prints a fixed line, never the setup containers' logs, and the next run retries it" {
    create_restored "$REPO_ROOT"
    # The test-copy guard refuses this value, logging a line upgrade must not pass on.
    set_env_value "$NAME" dhis2 DHIS2_TEST_COPY yes
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_failure
    assert_output --partial "DHIS2 2.43.2.1 didn't start: a setup container failed (pihx $NAME logs dhis2-setup, pihx $NAME logs dhis2-test-copy)."
    refute_output --partial 'must be true or false'
    assert_equal "$(cat "$DIR/dhis2-upgrade.pending")" 2.43.2.1
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp ' 2\.42\.7\.1 -> 2\.43\.2\.1 fixes=\[\] [0-9]+s failed$'

    # Not running, so not refused: the version is retried, and fails the same way.
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_failure
    assert_output --partial "DHIS2 2.43.2.1 didn't come up last time: retrying it"
    assert_output --partial "DHIS2 2.43.2.1 didn't start: a setup container failed"
    refute_output --partial 'must be true or false'
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
-- 2.30 with pre-2.29 leftovers: the old types table, the columns pointing at it, the old join table.
CREATE TABLE trackedentity (trackedentityid int PRIMARY KEY, name text);
INSERT INTO trackedentity VALUES (1, 'Person');
CREATE TABLE trackedentityattributevalues (trackedentityid int REFERENCES trackedentity, attributevalueid int);
-- A table 2.30 still uses (translations of the current types) with a pre-2.29 key to the old table.
CREATE TABLE trackedentitytranslations (trackedentityid int REFERENCES trackedentity, objecttranslationid int, trackedentitytypeid int);
CREATE TABLE trackedentitytype (trackedentitytypeid int PRIMARY KEY, name text);
INSERT INTO trackedentitytype VALUES (1, 'Person'), (2, 'QI- Person'), (5, 'Cylinder');
CREATE TABLE trackedentitytypeattribute (trackedentitytypeid int, trackedentityattributeid int);
INSERT INTO trackedentitytypeattribute VALUES (1, 10), (2, 20), (2, 21);
CREATE TABLE trackedentityinstance (trackedentityinstanceid int PRIMARY KEY, trackedentitytypeid int,
    trackedentityid int REFERENCES trackedentity);
-- 1: typeless, values fitting type 2 only (gets 2 by its attributes, not 1 by the legacy name);
-- 2: typed (kept); 3: typeless, enrolled in a program of type 2 (gets 2); 4: nothing to go on (stays
-- NULL; no legacy link, so the leftovers can still go); 6: typeless, legacy link, no values (gets 1 by
-- name); 7: values fitting no single type (gets 1 by name).
INSERT INTO trackedentityinstance VALUES (1, NULL, 1), (2, 5, NULL), (3, NULL, 1), (4, NULL, NULL), (6, NULL, 1), (7, NULL, 1);
CREATE TABLE trackedentityattributevalue (trackedentityinstanceid int, trackedentityattributeid int, value text);
INSERT INTO trackedentityattributevalue VALUES (1, 20, 'x'), (1, 21, 'y'), (7, 20, 'x'), (7, 10, 'z');
CREATE TABLE program (programid int PRIMARY KEY, trackedentitytypeid int, trackedentityid int REFERENCES trackedentity);
INSERT INTO program VALUES (7, 2, 1), (8, NULL, NULL);
CREATE TABLE programinstance (programinstanceid int PRIMARY KEY, programid int, trackedentityinstanceid int);
INSERT INTO programinstance VALUES (1, 8, 3), (2, 7, 3), (3, 8, 4);
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
    # Typeless tracked entities get their program's type, else the one type their attribute values fit,
    # else the type named as their pre-2.29 one; then the pre-2.29 tables and columns are dropped.
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc "SELECT string_agg(trackedentityinstanceid || '=' || coalesce(trackedentitytypeid::text, 'null'), ',' ORDER BY trackedentityinstanceid) FROM trackedentityinstance")" '1=2,2=5,3=2,4=null,6=1,7=1'
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc "SELECT to_regclass('trackedentity') IS NULL AND to_regclass('trackedentityattributevalues') IS NULL")" t
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc "SELECT count(*) FROM information_schema.columns WHERE table_name IN ('trackedentityinstance', 'program') AND column_name = 'trackedentityid'")" 0
    # A table still in use loses only its key to the old table.
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc "SELECT to_regclass('trackedentitytranslations') IS NOT NULL, (SELECT count(*) FROM pg_constraint WHERE conrelid = 'trackedentitytranslations'::regclass AND contype = 'f')")" 't|0'
}

@test "drop-sql-views.sql drops DHIS2's SQL views (views and materialized views named _view_*) and nothing else, and can run again" {
    local db; db="$(res db)"
    docker run -d --name "$db" -e POSTGRES_USER=dhis -e POSTGRES_DB=dhis -e POSTGRES_PASSWORD=Placeholder-1 \
        --health-cmd "pg_isready -h 127.0.0.1 -U dhis -d dhis" --health-interval 1s postgis/postgis:16-3.5 >/dev/null
    run "$UTILS/wait-for-healthy.sh" --container="$db" --timeout=300
    assert_success
    docker exec -i "$db" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE datavalue (value text);
CREATE VIEW _view_a AS SELECT value FROM datavalue;
CREATE VIEW _view_on_a AS SELECT value FROM _view_a;
CREATE MATERIALIZED VIEW _view_m AS SELECT value FROM datavalue;
CREATE VIEW keep_me AS SELECT value FROM datavalue;
CREATE VIEW x_view_y AS SELECT value FROM datavalue;
SQL
    run bash -c 'for i in 1 2; do docker exec -i "$1" psql -X -1 -U dhis -d dhis -q -v ON_ERROR_STOP=1 < "$2" || exit 1; done' \
        _ "$db" "$REPO_ROOT/services/dhis2/scripts/drop-sql-views.sql"
    assert_success
    run docker exec "$db" psql -U dhis -d dhis -tAc \
        "SELECT string_agg(viewname, ',' ORDER BY viewname) FROM pg_views WHERE schemaname = 'public'"
    assert_output 'geography_columns,geometry_columns,keep_me,x_view_y'   # PostGIS's own two kept too
    run docker exec "$db" psql -U dhis -d dhis -tAc "SELECT count(*) FROM pg_matviews"
    assert_output 0
}

@test "the pre-2.29 tracked entity tables stay while a tracked entity still typeless points at them" {
    local db; db="$(res db)"
    docker run -d --name "$db" -e POSTGRES_USER=dhis -e POSTGRES_DB=dhis -e POSTGRES_PASSWORD=Placeholder-1 \
        --health-cmd "pg_isready -h 127.0.0.1 -U dhis -d dhis" --health-interval 1s postgis/postgis:16-3.5 >/dev/null
    run "$UTILS/wait-for-healthy.sh" --container="$db" --timeout=300
    assert_success
    # Its legacy type's name matches no current type, and it has no enrollment or values to go on.
    docker exec -i "$db" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE trackedentity (trackedentityid int PRIMARY KEY, name text);
INSERT INTO trackedentity VALUES (1, 'Old type');
CREATE TABLE trackedentitytype (trackedentitytypeid int PRIMARY KEY, name text);
INSERT INTO trackedentitytype VALUES (1, 'Person');
CREATE TABLE trackedentitytypeattribute (trackedentitytypeid int, trackedentityattributeid int);
CREATE TABLE trackedentityinstance (trackedentityinstanceid int PRIMARY KEY, trackedentitytypeid int,
    trackedentityid int REFERENCES trackedentity);
INSERT INTO trackedentityinstance VALUES (1, NULL, 1);
CREATE TABLE trackedentityattributevalue (trackedentityinstanceid int, trackedentityattributeid int, value text);
CREATE TABLE program (programid int PRIMARY KEY, trackedentitytypeid int);
CREATE TABLE programinstance (programinstanceid int PRIMARY KEY, programid int, trackedentityinstanceid int);
SQL
    run docker exec -i "$db" psql -X -1 -U dhis -d dhis -q -v ON_ERROR_STOP=1 \
        < "$REPO_ROOT/services/dhis2/known-fixes/2.31.9/20-assign-missing-tracked-entity-types.sql"
    assert_success
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc 'SELECT trackedentitytypeid IS NULL, trackedentityid FROM trackedentityinstance')" 't|1'
    assert_equal "$(docker exec "$db" psql -U dhis -d dhis -tAc "SELECT name FROM trackedentity")" 'Old type'
}
