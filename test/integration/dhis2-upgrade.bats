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
