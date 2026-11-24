#!/usr/bin/env bats
# dhis2-db and dhis2: their backup scripts (run in backup-tools with the mounts and environment their
# with-backups.yaml gives, as backups-services.bats does for biometrics) and the restore of what they
# write. Synthetic data only. Only dhis2-db is started: starting dhis2 downloads its WAR (dhis2.bats).

load ../helpers

IMAGE="partnersinhealth/backup-tools:$("$REPO_ROOT/utils/hash-directory.sh" "$REPO_ROOT/images/backup-tools")"
PW='Backup-pw-1'
DBPW='Placeholder-1'

setup_file() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null 2>&1 \
        || docker build -q -t "$IMAGE" "$REPO_ROOT/images/backup-tools" >/dev/null
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    RESTORED="$(instance restored)"
    export DHIS2_DB_PASSWORD="$DBPW" DHIS2_DB_PORT=0 DHIS2_HTTP_PORT=0 DHIS2_VERSION=2.43.2.1
    export BACKUP_ARCHIVE_PASSWORD="$PW"
}
teardown() {
    remove_test_instance "$NAME"
    remove_test_instance "$RESTORED"
    common_teardown
}

write_dump() { # <path>
    cat > "$1" <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE TABLE datavalue (id integer);
INSERT INTO datavalue VALUES (1), (2), (3);
CREATE TABLE analytics_2024 (id integer);
INSERT INTO analytics_2024 VALUES (1);
-- As a DHIS2 SQL view on an analytics table makes one.
CREATE VIEW analytics_view AS SELECT id FROM analytics_2024;
CREATE TABLE flyway_schema_history (installed_rank integer, version text, success boolean);
INSERT INTO flyway_schema_history VALUES (1, '2.43.0.1', true);
SQL
}

# A DHIS2 home like RIMU's, files/ and apps/ at the top, plus what an instance adds.
write_home() { # <dir>
    mkdir -p "$1/files/a" "$1/apps"
    echo one > "$1/files/a/1.txt"
    echo two > "$1/files/2.txt"
    echo app > "$1/apps/app.zip"
    echo 'connection.password = hunter2-synthetic' > "$1/dhis.conf"
    echo 2.43.2.1 > "$1/.dhis2-version"
    # DHIS2's logs, and what a setup that failed before its rename leaves (it holds the password).
    mkdir -p "$1/logs"
    echo log > "$1/logs/dhis.log"
    echo 'connection.password = hunter2-synthetic' > "$1/.dhis.conf.new"
}

# The two backup scripts as the backups container runs them (with-backups.yaml). Extra docker args first.
dhis2_db_backup() {
    docker run --rm --network "${NAME}_default" -v "$BATS_TEST_TMPDIR/out:/run-dir" \
        -v "$REPO_ROOT/services/dhis2-db/scripts:/opt/backup-services/dhis2-db:ro" \
        -e BACKUP_RUN_DIR=/run-dir -e ARCHIVE_PASSWORD="$PW" -e DHIS2_DB_USER=dhis -e DHIS2_DB_NAME=dhis \
        -e DHIS2_DB_PASSWORD="$DBPW" --entrypoint bash "$IMAGE" /opt/backup-services/dhis2-db/backup.sh
}
dhis2_backup() {
    docker run --rm -v "$BATS_TEST_TMPDIR/out:/run-dir" \
        -v "$REPO_ROOT/services/dhis2/scripts:/opt/backup-services/dhis2:ro" \
        -v "${NAME}_dhis2-data:/sources/dhis2:ro" \
        -e BACKUP_RUN_DIR=/run-dir -e ARCHIVE_PASSWORD="$PW" --entrypoint bash "$IMAGE" /opt/backup-services/dhis2/backup.sh
}

@test "a backups run of a DHIS2 instance restores with initialize --from, and the summaries match" {
    "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    mkdir from home
    write_dump dump.sql
    gzip -c dump.sql > from/dhis2-db.sql.gz
    write_home home
    tar czf from/dhis2.tar.gz -C home .
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from from
    assert_success
    # Only the database: starting dhis2 would download its WAR.
    instance_compose_of "$NAME" up -d dhis2-db >/dev/null 2>&1
    "$UTILS/wait-for-healthy.sh" --container="$NAME-dhis2-db" --timeout=120 >/dev/null
    "$BIN/pihx" "$NAME" summary --output=before.txt
    run cat before.txt
    assert_output --partial $'[dhis2]\nfiles 2\napps 1\nversion 2.43.2.1'
    assert_output --partial 'rows datavalue 3'

    mkdir out
    run dhis2_db_backup
    assert_success
    refute_output --partial "$PW"
    refute_output --partial "$DBPW"
    run dhis2_backup
    assert_success
    refute_output --partial "$PW"
    run ls out
    assert_output $'dhis2-db.sql.7z\ndhis2.7z'
    # Only files/, apps/ and the version marker: no dhis.conf (setup writes it), .dhis.conf.new or logs/.
    run docker run --rm -v "$BATS_TEST_TMPDIR/out:/o:ro" --entrypoint bash "$IMAGE" -c \
        "set -eo pipefail; printf '%s\n' '$PW' | 7z l -slt /o/dhis2.7z | grep '^Path ='"
    assert_success
    assert_line 'Path = dhis2/.dhis2-version'
    assert_line 'Path = dhis2/files/2.txt'
    refute_output --partial 'dhis.conf'
    refute_output --partial 'logs'
    # The dump is there (a failed extraction fails the test), with the analytics tables' definitions
    # (a view can depend on one) but not their rows.
    run docker run --rm -v "$BATS_TEST_TMPDIR/out:/o:ro" --entrypoint bash "$IMAGE" -c \
        "set -eo pipefail; printf '%s\n' '$PW' | 7z x -so /o/dhis2-db.sql.7z"
    assert_success
    assert_output --partial 'COPY public.datavalue'
    assert_output --partial 'CREATE TABLE public.analytics_2024'
    assert_output --partial 'CREATE VIEW public.analytics_view'
    refute_output --partial 'COPY public.analytics_2024'

    docker rm -f "$NAME-dhis2-db" >/dev/null
    "$BIN/pihx" "$RESTORED" create --services=dhis2-db,dhis2 >/dev/null
    ARCHIVE_PASSWORD="$PW" run timeout 300 "$BIN/pihx" "$RESTORED" initialize --from out
    assert_success
    "$BIN/pihx" "$RESTORED" summary --output=after.txt
    run diff before.txt after.txt
    assert_success
    # The view restored, on an empty analytics table.
    instance_compose_of "$RESTORED" up -d dhis2-db >/dev/null 2>&1
    "$UTILS/wait-for-healthy.sh" --container="$RESTORED-dhis2-db" --timeout=120 >/dev/null
    run docker exec "$RESTORED-dhis2-db" psql -U dhis -d dhis -tAc 'SELECT count(*) FROM analytics_view'
    assert_output 0
}

@test "the backups service gets both DHIS2 scripts and what they need" {
    "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2,backups >/dev/null
    run "$BIN/pihx" "$NAME" compose config
    assert_success
    assert_output --partial "services/dhis2-db/scripts"
    assert_output --partial "/opt/backup-services/dhis2-db"
    assert_output --partial "services/dhis2/scripts"
    assert_output --partial "/opt/backup-services/dhis2"
    assert_output --partial "target: /sources/dhis2"
    assert_output --partial "DHIS2_DB_USER"
}

@test "initialize restores the RIMU layout: dhis2.tar.gz with files/ and apps/ at the top" {
    "$BIN/pihx" "$NAME" create --services=dhis2-db,dhis2 >/dev/null
    mkdir from home
    write_dump from/dhis2-db.sql
    write_home home
    rm home/dhis.conf home/.dhis2-version
    tar czf from/dhis2.tar.gz -C home files apps
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from from
    assert_success
    run docker run --rm -v "${NAME}_dhis2-data:/d:ro" "$ALPINE_IMAGE" find /d -type f
    assert_line /d/files/a/1.txt
    assert_line /d/files/2.txt
    assert_line /d/apps/app.zip
    refute_output --partial restore-staging
    "$BIN/pihx" "$NAME" summary --output=s.txt
    run cat s.txt
    assert_output --partial $'[dhis2]\nfiles 2\napps 1\nversion none'
}
