#!/usr/bin/env bats
# dhis2-db: PostGIS for a DHIS2 instance, with server options from DHIS2_DB_OPT_*, restored from
# pg_dump output (synthetic dumps written here; never real data) and summarized.

load ../helpers

BACKUP_TOOLS="partnersinhealth/backup-tools:$("$REPO_ROOT/utils/hash-directory.sh" "$REPO_ROOT/images/backup-tools")"

setup_file() {
    docker image inspect "$BACKUP_TOOLS" >/dev/null 2>&1 || docker pull -q "$BACKUP_TOOLS" >/dev/null 2>&1 \
        || docker build -q -t "$BACKUP_TOOLS" "$REPO_ROOT/images/backup-tools" >/dev/null
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    export DHIS2_DB_PASSWORD='Placeholder-1'
    export DHIS2_DB_PORT=0
}
teardown() {
    remove_test_instance "$NAME"
    common_teardown
}

create() {
    "$BIN/pihx" "$NAME" create --services=dhis2-db >/dev/null
}

# A small dump like pg_dump's: PostGIS, a datavalue table with 3 rows, Flyway's history.
write_dump() { # <path>
    cat > "$1" <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE TABLE datavalue (id integer);
INSERT INTO datavalue VALUES (1), (2), (3);
CREATE TABLE flyway_schema_history (installed_rank integer, version text, success boolean);
INSERT INTO flyway_schema_history VALUES (1, '2.42.0.1', true), (2, '2.43.0.1', true), (3, '2.44.0.1', false);
SQL
}

EXPECTED_SUMMARY=$'[dhis2-db]\nflyway 2.43.0.1\nrows datavalue 3'

@test "dhis2-db starts healthy with PostGIS and the declared options" {
    create
    run "$BIN/pihx" "$NAME" start
    assert_success
    run "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2-db" --timeout=120
    assert_success
    run docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc 'SHOW max_locks_per_transaction'
    assert_output 96
    run docker exec "$NAME-dhis2-db" psql -U dhis -d dhis -tAc 'SELECT postgis_version()'
    assert_success
}

@test "dhis2-db has no default password" {
    unset DHIS2_DB_PASSWORD
    run "$BIN/pihx" "$NAME" create --services=dhis2-db
    assert_failure
    assert_output --partial DHIS2_DB_PASSWORD
}

@test "initialize restores a .sql.gz dump, and summary counts its rows" {
    create
    mkdir from
    write_dump dump.sql
    gzip -c dump.sql > from/dhis2-db.sql.gz
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from from
    assert_success
    # Stopped: read from the volume.
    run "$BIN/pihx" "$NAME" summary
    assert_success
    assert_output "$EXPECTED_SUMMARY"
    # Running: read from the container.
    "$BIN/pihx" "$NAME" start >/dev/null
    "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2-db" --timeout=120 >/dev/null
    run "$BIN/pihx" "$NAME" summary
    assert_success
    assert_output "$EXPECTED_SUMMARY"
}

@test "initialize restores a .sql.7z archive" {
    create
    mkdir from
    write_dump dump.sql
    docker run --rm -v "$PWD:/w" -w /w --entrypoint 7z "$BACKUP_TOOLS" a -ppw -mhe=on from/dhis2-db.sql.7z dump.sql >/dev/null
    ARCHIVE_PASSWORD=pw run timeout 300 "$BIN/pihx" "$NAME" initialize --from from
    assert_success
    run "$BIN/pihx" "$NAME" summary
    assert_output "$EXPECTED_SUMMARY"
}

@test "initialize refuses an existing dhis2-db-data volume" {
    create
    mkdir from
    write_dump from/dhis2-db.sql
    docker volume create "${NAME}_dhis2-db-data" >/dev/null
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from from
    assert_failure
    assert_output --partial "${NAME}_dhis2-db-data already exists"
}
