#!/usr/bin/env bats
# dhis2-upgrade steps a DHIS2 instance through an upgrade path: each step's WAR, its SQL, the new
# version and Tomcat tag in env, then a start. Against the stub image tagged as each step's "Tomcat",
# with a fixture path, fixture WARs and fixture SQL.

load ../helpers

setup_file() {
    build_stub_dhis2_image
    for t in step1 step2 step3; do docker tag "$STUB_DHIS2_IMAGE" "$STUB_DHIS2_IMAGE:$t"; done
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    DIR="$OPENMRS_DOCKER_HOME/$NAME"
    local v sha
    : > path
    for v in 1.0 2.0 3.0; do
        echo "war $v" > "w$v.war"
        sha=$(sha256sum "w$v.war" | cut -d' ' -f1)
        echo "$v step${v%.0} file://$PWD/w$v.war $sha" >> path
    done
    mkdir -p sql/2.0 sql/3.0
    echo "INSERT INTO marker VALUES ('2.0');" > sql/2.0/10-step.sql
    echo "INSERT INTO marker VALUES ('3.0');" > sql/3.0/10-step.sql
    export DHIS2_UPGRADE_PATH="$PWD/path" DHIS2_UPGRADE_SQL_DIR="$PWD/sql" DHIS2_UPGRADE_STEP_TIMEOUT=120
    SERVICES=dhis2-db,dhis2 DHIS2_IMAGE_NAME="$STUB_DHIS2_IMAGE" DHIS2_IMAGE_TAG=step1 DHIS2_VERSION=1.0 \
        create_instance "$NAME"
    "$UTILS/dhis2-war.sh" --instance="$NAME" --version=1.0 >/dev/null 2>&1
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2-db" --timeout=120 >/dev/null 2>&1
    docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -qc 'CREATE TABLE marker (v text)'
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

markers() { docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc 'SELECT v FROM marker ORDER BY v' | paste -sd, -; }
env_value() { sed -n "s/^$1='\(.*\)'$/\1/p" "$DIR/env"; }

@test "runs a step's SQL then starts the new version" {
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 </dev/null
    assert_success
    assert_equal "$(markers)" 2.0
    assert_equal "$(env_value DHIS2_VERSION)" 2.0
    assert_equal "$(env_value DHIS2_IMAGE_TAG)" step2
    assert [ -s "$DIR/wars/dhis2-2.0.war" ]
    run docker inspect -f '{{.Config.Image}}' "$NAME-dhis2"
    assert_output "$STUB_DHIS2_IMAGE:step2"
    run cat "$DIR/dhis2-upgrade.log"
    assert_output --regexp '1\.0 -> 2\.0 .*step2.*10-step\.sql.* ok'
}

@test "resumes from the current version" {
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" <<< n
    assert_success
    assert_output --partial 'Continue to 3.0?'
    assert_equal "$(env_value DHIS2_VERSION)" 2.0
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" </dev/null
    assert_success
    assert_equal "$(markers)" 2.0,3.0
    assert_equal "$(env_value DHIS2_VERSION)" 3.0
}

@test "stops on a failing SQL file without changing the version" {
    echo 'SELECT * FROM no_such_table;' > sql/2.0/20-bad.sql
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" </dev/null
    assert_failure
    assert_output --partial 20-bad.sql
    assert_equal "$(env_value DHIS2_VERSION)" 1.0
    run cat "$DIR/dhis2-upgrade.log"
    assert_output --partial failed
}

@test "stops as soon as Tomcat fails to deploy DHIS2, rather than waiting out the step timeout" {
    # Logs what Tomcat does when DHIS2's context fails (e.g. a Flyway error), and never answers.
    docker build -q -t "$STUB_DHIS2_IMAGE:stepfail" - >/dev/null <<DOCKERFILE
FROM $STUB_DHIS2_IMAGE
CMD ["sh", "-c", "echo 'SEVERE Context [/dhis] startup failed due to previous errors'; exec sleep 300"]
DOCKERFILE
    sed -i 's/^2.0 step2 /2.0 stepfail /' path
    SECONDS=0
    DHIS2_UPGRADE_STEP_TIMEOUT=600 run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" </dev/null
    assert_failure
    assert_output --partial 'startup failed due to previous errors'
    assert_output --partial "DHIS2 2.0 didn't come up"
    assert [ "$SECONDS" -lt 120 ]
}

@test "run again after a version failed to come up, retries it, SQL and all" {
    docker build -q -t "$STUB_DHIS2_IMAGE:stepfail" - >/dev/null <<DOCKERFILE
FROM $STUB_DHIS2_IMAGE
CMD ["sh", "-c", "echo 'SEVERE Context [/dhis] startup failed due to previous errors'; exec sleep 300"]
DOCKERFILE
    sed -i 's/^2.0 step2 /2.0 stepfail /' path
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 </dev/null
    assert_failure
    assert_equal "$(env_value DHIS2_VERSION)" 2.0
    sed -i 's/^2.0 stepfail /2.0 step2 /' path   # the fix
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 </dev/null
    assert_success
    assert_output --partial 'DHIS2 2.0 is up'
    assert_equal "$(markers)" 2.0,2.0   # its SQL ran again
    run tail -n 1 "$DIR/dhis2-upgrade.log"
    assert_output --regexp ' 1\.0 -> 2\.0 .* ok$'
    run docker inspect -f '{{.Config.Image}}' "$NAME-dhis2"
    assert_output "$STUB_DHIS2_IMAGE:step2"
}

@test "run again after it was interrupted while a version was starting, retries that version" {
    sed -i 's/^2.0 step2 /2.0 stepfail /' path
    docker build -q -t "$STUB_DHIS2_IMAGE:stepfail" - >/dev/null <<DOCKERFILE
FROM $STUB_DHIS2_IMAGE
CMD ["sleep", "300"]
DOCKERFILE
    DHIS2_UPGRADE_STEP_TIMEOUT=300 timeout -s TERM 30 "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 \
        </dev/null >/dev/null 2>&1 || true
    assert_equal "$(env_value DHIS2_VERSION)" 2.0
    sed -i 's/^2.0 stepfail /2.0 step2 /' path
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 </dev/null
    assert_success
    assert_output --partial 'DHIS2 2.0 is up'
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 </dev/null
    assert_output --partial 'nothing to do'
}

@test "stops on a WAR it can't fetch before changing anything" {
    sed -i "s|^2.0 step2 \(file://[^ ]*\) .*|2.0 step2 \1 $(printf '0%.0s' {1..64})|" path
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" </dev/null
    assert_failure
    assert_output --partial SHA-256
    assert_equal "$(markers)" ''
    assert_equal "$(env_value DHIS2_VERSION)" 1.0
}

@test "extra-sql-dir runs after the built-in files" {
    mkdir -p extra/2.0
    echo "UPDATE marker SET v = v || '+extra';" > extra/2.0/10-site.sql
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 --extra-sql-dir="$PWD/extra" </dev/null
    assert_success
    assert_equal "$(markers)" 2.0+extra
}

@test "upgrades an instance that has no containers yet" {
    # As initialize leaves a restored instance.
    "$BIN/openmrs-docker" "$NAME" stop >/dev/null 2>&1
    run "$UTILS/dhis2-upgrade.sh" --instance="$NAME" --to=2.0 </dev/null
    assert_success
    assert_equal "$(markers)" 2.0
    run docker inspect -f '{{.State.Running}} {{.Config.Image}}' "$NAME-dhis2"
    assert_output "true $STUB_DHIS2_IMAGE:step2"
}

@test "the legacy trackedentityaudit fix renames only the old table, before 2.41 renames its own" {
    docker exec -i "$NAME-dhis2-db" psql -U dhis -d dhis -q <<'SQL'
CREATE TABLE trackedentityaudit (trackedentityauditid int, visitor varchar(255), accessedmodule varchar(255));
INSERT INTO trackedentityaudit VALUES (1, 'admin', 'tracker');
CREATE TABLE trackedentityinstanceaudit (trackedentityinstanceauditid int);
SQL
    local fix="$REPO_ROOT/docker/dhis2/known-fixes/2.41.8.1/10-rename-legacy-trackedentityaudit.sql"
    docker exec -i "$NAME-dhis2-db" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 < "$fix"
    run docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc "SELECT visitor FROM trackedentityaudit_legacy"
    assert_output admin
    # After 2.41's own rename, trackedentityaudit is the new table: left alone.
    docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -qc 'ALTER TABLE trackedentityinstanceaudit RENAME TO trackedentityaudit'
    docker exec -i "$NAME-dhis2-db" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 < "$fix"
    run docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc "SELECT to_regclass('trackedentityaudit') IS NOT NULL"
    assert_output t
}

@test "the built-in and known fixes are idempotent" {
    local f
    docker exec -i "$NAME-dhis2-db" psql -U dhis -d dhis -q <<'SQL'
CREATE TABLE userrole (userroleid int PRIMARY KEY);
CREATE TABLE program_userroles (programid int, userroleid int);
CREATE TABLE dataelementoperand (dataelementoperandid int PRIMARY KEY);
CREATE TABLE sectiongreyedfields (dataelementoperandid int);
CREATE TABLE datasetoperands (dataelementoperandid int);
CREATE TABLE program_attribute_group (programtrackedentityattributegroupid int);
SQL
    for f in "$REPO_ROOT"/docker/dhis2/upgrade-sql/*/*.sql "$REPO_ROOT"/docker/dhis2/known-fixes/*/*.sql; do
        run bash -c 'for i in 1 2; do docker exec -i "$1" psql -U dhis -d dhis -q -v ON_ERROR_STOP=1 < "$2" || exit 1; done' _ "$NAME-dhis2-db" "$f"
        assert_success
    done
}
