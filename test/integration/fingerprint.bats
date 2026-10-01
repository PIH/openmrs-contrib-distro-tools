#!/usr/bin/env bats
# fingerprint summarizes a database (and data directory) so a source and its restore can be diffed.

load ../helpers

setup_file() {
    export SRC_DB="$(file_res src)"
    start_source_db "$SRC_DB"
    # OpenMRS-shaped tables, objects a restore has to bring along, and a value that must never be
    # written out. Only openmrs: a logical restore brings no other database.
    mysql_exec "$SRC_DB" openmrs "
        DROP DATABASE malawi;
        CREATE TABLE openmrs.encounter (encounter_id INT PRIMARY KEY, date_created DATETIME) ENGINE=InnoDB;
        INSERT INTO openmrs.encounter VALUES (1, '2026-09-01 10:00:00'), (2, '2026-09-02 11:00:00');
        CREATE TABLE openmrs.users (user_id INT PRIMARY KEY, password VARCHAR(64)) ENGINE=InnoDB;
        INSERT INTO openmrs.users VALUES (1, 's3cret-hash-value');
        CREATE VIEW openmrs.encounter_ids AS SELECT encounter_id FROM openmrs.encounter;
        CREATE TRIGGER openmrs.encounter_ins BEFORE INSERT ON openmrs.encounter FOR EACH ROW SET NEW.encounter_id = NEW.encounter_id;
        CREATE FUNCTION openmrs.answer() RETURNS INT DETERMINISTIC RETURN 42;"
    export BEFORE="$BATS_FILE_TMPDIR/before.txt"
    MYSQL_PASSWORD=openmrs "$UTILS/fingerprint.sh" --container="$SRC_DB" --output="$BEFORE"
}
teardown_file() { common_teardown_file; }

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

without_accounts() { # <fingerprint file>
    awk '/^\[/ { skip = ($0 == "[accounts]") } !skip' "$1"
}

@test "covers each section, and writes no row contents" {
    run cat "$BEFORE"
    assert_line 'openmrs tables=3'
    assert_line 'openmrs.encounter 2'
    assert_line 'openmrs.marker 1'
    assert_line 'openmrs function answer'
    assert_line 'openmrs trigger encounter_ins'
    assert_line 'openmrs view encounter_ids'
    assert_line 'openmrs.encounter max_encounter_id=2 max_date_created=2026-09-02 11:00:00'
    assert_line 'openmrs.users max_user_id=1'
    assert_line 'openmrs@%'
    assert_line --regexp '^version 5\.6\.'
    refute_output --partial 's3cret-hash-value'
}

@test "a logical restore fingerprints the same as its source before the first start, apart from accounts" {
    MYSQL_PASSWORD=openmrs "$UTILS/backup-mysqldump.sh" --container="$SRC_DB" --user=root --output=dump.sql 2>/dev/null
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_success
    "$UTILS/fingerprint.sh" --db-volume="${NAME}_db-data" --output=after.txt
    run diff <(without_accounts "$BEFORE") <(without_accounts after.txt)
    assert_success
}

@test "a physical (Percona) restore fingerprints the same as its source, apart from accounts" {
    MYSQL_PASSWORD=openmrs ARCHIVE_PASSWORD=pw "$UTILS/backup-percona.sh" --container="$SRC_DB" \
        --volume="$SRC_DB-data" --output=backup.7z >/dev/null 2>&1
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    ARCHIVE_PASSWORD=pw run_initialize "$NAME" RESTORE_MYSQL_PERCONA_PATH=backup.7z
    assert_success
    "$UTILS/fingerprint.sh" --db-volume="${NAME}_db-data" --output=after.txt
    run diff <(without_accounts "$BEFORE") <(without_accounts after.txt)
    assert_success
}

@test "a row written after the backup shows in [rows] and [recent]" {
    MYSQL_PASSWORD=openmrs "$UTILS/backup-mysqldump.sh" --container="$SRC_DB" --user=root --output=dump.sql 2>/dev/null
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    "$UTILS/fingerprint.sh" --db-volume="${NAME}_db-data" --output=restored.txt
    # the source moves on: a copy of the source's volume stands in, so the shared source stays as is
    local later=$(res later)
    docker run --rm -v "$SRC_DB-data:/from:ro" -v "$later:/to" alpine:3.21 cp -a /from/. /to/
    docker run -d --name "$later" -v "$later:/var/lib/mysql" "$MYSQL_IMAGE" >/dev/null
    wait_for_mysql "$later" root openmrs
    mysql_exec "$later" openmrs "INSERT INTO openmrs.encounter VALUES (3, '2026-09-03 12:00:00')"
    MYSQL_PASSWORD=openmrs "$UTILS/fingerprint.sh" --container="$later" --output=later.txt
    run diff restored.txt later.txt
    assert_failure
    assert_output --partial '> openmrs.encounter 3'
    assert_output --partial '> openmrs.encounter max_encounter_id=3 max_date_created=2026-09-03 12:00:00'
}

@test "--host reads a MySQL over TCP the same as --container" {
    local db port
    db=$(res hostdb)
    docker run -d --name "$db" -p 127.0.0.1::3306 -e MYSQL_ROOT_PASSWORD=openmrs -e MYSQL_DATABASE=openmrs "$MYSQL_IMAGE" >/dev/null
    wait_for_mysql "$db" root openmrs
    port=$(docker port "$db" 3306 | head -1 | cut -d: -f2)
    MYSQL_PASSWORD=openmrs "$UTILS/fingerprint.sh" --container="$db" --output=c.txt
    MYSQL_PASSWORD=openmrs "$UTILS/fingerprint.sh" --host=127.0.0.1 --port="$port" --output=h.txt
    run diff c.txt h.txt
    assert_success
}

@test "--db-volume refuses while a container is using the volume" {
    run "$UTILS/fingerprint.sh" --db-volume="$SRC_DB-data"
    assert_failure
    assert_output --partial "is in use by a running container"
}

@test "--data-dir summarizes each top-level folder, leaving out distribution artifacts when asked" {
    mkdir -p data/complex_obs/2026 data/modules data/.openmrs-lib-cache
    head -c 1000 /dev/urandom > data/complex_obs/2026/a.png
    head -c 500 /dev/urandom > data/complex_obs/b.pdf
    head -c 2000 /dev/urandom > data/modules/x.omod
    echo 'connection.password=s3cret' > data/openmrs-runtime.properties
    MYSQL_PASSWORD=openmrs run "$UTILS/fingerprint.sh" --container="$SRC_DB" --data-dir="$BATS_TEST_TMPDIR/data"
    assert_line 'complex_obs/ files=2 bytes=1500'
    assert_line 'modules/ files=1 bytes=2000'
    assert_line --regexp '^\(top level\) files=1 bytes=[0-9]+$'
    refute_output --partial 's3cret'
    MYSQL_PASSWORD=openmrs run "$UTILS/fingerprint.sh" --container="$SRC_DB" --data-dir="$BATS_TEST_TMPDIR/data" \
        --exclude-distribution-artifacts
    assert_line 'complex_obs/ files=2 bytes=1500'
    refute_output --partial 'modules/'
    refute_output --partial '.openmrs-lib-cache'
}
