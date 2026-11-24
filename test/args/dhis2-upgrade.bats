#!/usr/bin/env bats
# pihx <instance> dhis2 upgrade's checks before it touches anything (no DHIS2, no containers), the
# failure summary it prints (scripts/flyway-errors.sh, fed log text), and the known fixes' layout.

load ../helpers

SUMMARY="$REPO_ROOT/services/dhis2/scripts/flyway-errors.sh"

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    export DHIS2_DB_PASSWORD='Placeholder-1'
}
teardown() {
    remove_test_instance "$NAME"
    common_teardown
}

create_dhis2() { # <version>
    DHIS2_VERSION="$1" "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
}

# Nothing was started and nothing was written.
assert_untouched() {
    run docker ps -aq --filter "label=com.docker.compose.project=$NAME"
    assert_output ''
    assert [ ! -e "$PIHX_HOME/$NAME/dhis2-upgrade.pending" ]
    assert [ ! -e "$PIHX_HOME/$NAME/dhis2-upgrade.log" ]
}

@test "upgrade is listed among dhis2's commands" {
    create_dhis2 2.33.9
    run "$BIN/pihx" "$NAME" dhis2
    assert_success
    assert_output --partial upgrade
}

@test "refuses a version that isn't in the versions list" {
    create_dhis2 2.29.0
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_failure
    assert_output --partial "DHIS2 2.29.0 isn't in services/dhis2/scripts/versions"
    assert_untouched
}

@test "--to before the current version does nothing and says so" {
    create_dhis2 2.33.9
    run "$BIN/pihx" "$NAME" dhis2 upgrade --to=2.32.7
    assert_success
    assert_output --partial "$NAME is on DHIS2 2.33.9: nothing to do"
    assert_untouched
}

@test "on the last version in the list, there's nothing to do" {
    create_dhis2 2.43.2.1
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_success
    assert_output --partial 'nothing to do'
    assert_untouched
}

@test "refuses a --to version that isn't in the versions list" {
    create_dhis2 2.33.9
    run "$BIN/pihx" "$NAME" dhis2 upgrade --to=2.99
    assert_failure
    assert_output --partial "DHIS2 2.99 isn't in services/dhis2/scripts/versions"
    assert_untouched
}

@test "refuses an unknown argument" {
    create_dhis2 2.33.9
    run "$BIN/pihx" "$NAME" dhis2 upgrade --force
    assert_failure
    assert_output --partial 'unknown argument: --force'
    assert_untouched
}

@test "refuses a --with-fix that isn't a known fix, naming it" {
    create_dhis2 2.34.9
    run "$BIN/pihx" "$NAME" dhis2 upgrade --with-fix=2.35.14/99-no-such-fix.sql
    assert_failure
    assert_output --partial "2.35.14/99-no-such-fix.sql isn't a known fix (services/dhis2/known-fixes/)"
    assert_untouched
}

@test "refuses a --with-fix that isn't <version>/<file>.sql under known-fixes" {
    create_dhis2 2.34.9
    local fix
    for fix in ../scripts/versions 2.35.14 2.35.14/../2.37.10/10-drop-old-translation-tables.sql \
            2.35.14/.hidden.sql; do
        run "$BIN/pihx" "$NAME" dhis2 upgrade --with-fix="$fix"
        assert_failure
        assert_output --partial "--with-fix=$fix: expected <version>/<file>.sql"
    done
    assert_untouched
}

@test "refuses a --with-fix for a version this run doesn't step to" {
    create_dhis2 2.34.9
    # One step by default: to 2.35.14, not 2.37.10.
    run "$BIN/pihx" "$NAME" dhis2 upgrade --with-fix=2.37.10/10-drop-old-translation-tables.sql
    assert_failure
    assert_output --partial "--with-fix=2.37.10/10-drop-old-translation-tables.sql is for DHIS2 2.37.10, which this run doesn't step to (2.34.9 -> 2.35.14)"
    assert_untouched
}

@test "the failure summary prints the migration and SQL state, never the error's message or detail" {
    cat > log <<'LOG'
2026-11-23 10:00:00 INFO  Migrating schema "public" to version "2.41.23 - Something"
* ERROR 2026-11-23T10:00:01,000 Migration of schema "public" to version "2.41.24 - TrackedEntityInstanceToTrackedEntity" failed! Changes successfully rolled back. (DbMigrate.java [main])
org.flywaydb.core.internal.command.DbMigrate$FlywayMigrateException: Migration V2_41_24__TrackedEntityInstanceToTrackedEntity.sql failed
--------------------------------------------------------------------------------
SQL State  : 23505
Error Code : 0
Message    : ERROR: duplicate key value violates unique constraint "uk_trackedentity"
  Detail: Key (id)=(secret-row) already exists.
Location   : org/hisp/dhis/db/migration/v41/V2_41_24__TrackedEntityInstanceToTrackedEntity.sql
Line       : 12
Statement  : INSERT INTO trackedentity VALUES ('secret-row')
SEVERE [main] org.apache.catalina.core.StandardContext.startInternal Context [/dhis] startup failed due to previous errors
LOG
    run bash "$SUMMARY" < log
    assert_success
    assert_line '  migration 2.41.24 - TrackedEntityInstanceToTrackedEntity failed'
    assert_line '  migration V2_41_24__TrackedEntityInstanceToTrackedEntity.sql failed'
    assert_line '  SQL state 23505'
    refute_output --partial secret-row
    refute_output --partial 'duplicate key'
    refute_output --partial trackedentity\ VALUES
    assert_equal "${#lines[@]}" 3
}

@test "the failure summary prints nothing for a log without a Flyway failure, or one that quotes data" {
    printf '%s\n' 'Tomcat started' 'Key (id)=(secret-row)' > log
    run bash "$SUMMARY" < log
    assert_success
    assert_output ''
    # A version or SQL state with anything but the characters they're made of isn't printed.
    printf '%s\n' 'Migration of schema "public" to version "2.41.24 (secret-row)" failed' \
        'SQL State  : 23505 secret-row' > log
    run bash "$SUMMARY" < log
    refute_output --partial secret-row
}

@test "every known fix is <version>/<file>.sql for a version in the versions list" {
    local versions="$REPO_ROOT/services/dhis2/scripts/versions" fix v
    for fix in "$REPO_ROOT"/services/dhis2/known-fixes/*/*; do
        v=$(basename "$(dirname "$fix")")
        assert [ -n "$(awk -v v="$v" '!/^#/ && $1 == v' "$versions")" ]
        [[ $(basename "$fix") =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.sql$ ]] || fail "$fix isn't a .sql file name"
    done
}

@test "refuses an instance whose database volume doesn't exist yet" {
    create_dhis2 2.42.7.1
    run "$BIN/pihx" "$NAME" dhis2 upgrade
    assert_failure
    assert_output --partial "${NAME}_dhis2-db-data doesn't exist: initialize or start $NAME first, on DHIS2 2.42.7.1"
    assert_untouched
}
