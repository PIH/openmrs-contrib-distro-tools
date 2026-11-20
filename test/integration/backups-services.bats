#!/usr/bin/env bats
# Each backed-up service beyond openmrs-db and openmrs (backups.bats): its backup in the backups
# container, and its restore with initialize --from, through bin/pihx where its images are public.
# biometrics' image is private, so its backup script runs on a SQLite fixture, and initialize (which
# runs only the restore container) restores it.

load ../helpers

IMAGE="partnersinhealth/backup-tools:$("$REPO_ROOT/utils/hash-directory.sh" "$REPO_ROOT/images/backup-tools")"
PW='Backup-pw-1'
SA='Sa-Placeholder-1'

# One SQL Server or OpenHIM at a time from this file: each takes gigabytes of memory.
setup_file() {
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null 2>&1 \
        || docker build -q -t "$IMAGE" "$REPO_ROOT/images/backup-tools" >/dev/null
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    RESTORED="$(instance restored)"
    export BACKUP_ARCHIVE_PASSWORD="$PW"
}
teardown() {
    remove_test_instance "$NAME"
    remove_test_instance "$RESTORED"
    common_teardown
}

# The one run directory in <dir> (from copy-backup), listed.
run_files() { ls "$1"; }

# --- biometrics -------------------------------------------------------------------------------------

@test "biometrics: the SQLite database is dumped consistently, even in WAL mode, and restores with initialize" {
    # The source: an instance with biometrics, whose volume holds a database in WAL mode (as
    # Neurotechnology's library may keep it), owned by the image's user, with a blob like a template.
    BIOMETRICS_LICENSE_BASE64=QUJDRA== "$BIN/pihx" "$NAME" create --services=biometrics >/dev/null
    local vol="${NAME}_biometrics-data"
    docker volume create "$vol" >/dev/null
    docker run --rm -v "$vol:/d" --entrypoint bash "$IMAGE" -c \
        "sqlite3 /d/biometrics.db \"PRAGMA journal_mode=WAL; CREATE TABLE subjects(id TEXT PRIMARY KEY, template BLOB);
         INSERT INTO subjects VALUES ('p1', x'00ff10'), ('p2', randomblob(64));\" >/dev/null; chown -R 9000:9000 /d"
    "$BIN/pihx" "$NAME" summary --output=before.txt
    run cat before.txt
    assert_output $'[biometrics]\nrows subjects 2'
    mkdir out
    # As the backups container runs it (with-backups.yaml): the volume read-write, the script mounted.
    run docker run --rm -v "$vol:/sources/biometrics-data" -v "$BATS_TEST_TMPDIR/out:/run-dir" \
        -v "$REPO_ROOT/services/biometrics/scripts/backup.sh:/backup.sh:ro" \
        -e BACKUP_RUN_DIR=/run-dir -e ARCHIVE_PASSWORD="$PW" --entrypoint bash "$IMAGE" /backup.sh
    assert_success
    assert_output 'biometrics: dumping /sources/biometrics-data/biometrics.db'
    run ls out
    assert_output biometrics.sql.7z

    BIOMETRICS_LICENSE_BASE64=QUJDRA== "$BIN/pihx" "$RESTORED" create --services=biometrics >/dev/null
    ARCHIVE_PASSWORD="$PW" run timeout 300 "$BIN/pihx" "$RESTORED" initialize --from out
    assert_success
    assert_output --partial 'biometrics: loading biometrics.sql.7z into biometrics.db'
    run docker run --rm -v "${RESTORED}_biometrics-data:/d" --entrypoint bash "$IMAGE" -c \
        'sqlite3 /d/biometrics.db "SELECT id, hex(template), length(template) FROM subjects ORDER BY id"; stat -c "%u:%g %n" /d /d/biometrics.db; ls -A /d'
    assert_line '9000:9000 /d'
    assert_line '9000:9000 /d/biometrics.db'
    assert_line --index 0 'p1|00FF10|3'
    assert_line --index 1 --regexp '^p2\|[0-9A-F]{128}\|64$'
    refute_output --partial '.restore'
    # The restored instance summarizes as the source did.
    "$BIN/pihx" "$RESTORED" summary --output=after.txt
    run diff before.txt after.txt
    assert_success
    # Nothing the backup or the summaries read was left owned by root.
    run docker run --rm -v "$vol:/d" --entrypoint find "$IMAGE" /d -not -user 9000
    assert_output ''
}

@test "biometrics: a server that hasn't created its database writes nothing" {
    mkdir out
    run docker run --rm -v "$BATS_TEST_TMPDIR/out:/run-dir" \
        -v "$REPO_ROOT/services/biometrics/scripts/backup.sh:/backup.sh:ro" \
        -e BACKUP_RUN_DIR=/run-dir -e ARCHIVE_PASSWORD="$PW" --entrypoint bash "$IMAGE" /backup.sh
    assert_success
    assert_output --partial "nothing to back up"
    run ls out
    assert_output ''
}

# --- openhim ----------------------------------------------------------------------------------------

start_openhim() { # <name>
    OPENHIM_PASSWORD='Openhim-pw-1' OPENHIM_CONSOLE_HOST_PORT=0 OPENHIM_ADMIN_API_HOST_PORT=0 \
        OPENHIM_ROUTER_HTTP_HOST_PORT=0 "$BIN/pihx" "$1" create --services="$2" >/dev/null
}

mongo_eval() { # <name> <javascript>
    docker exec "$1-mongo-db" mongosh --quiet openhim --eval "$2"
}

@test "openhim: its MongoDB database is backed up and restores with initialize, and openhim-setup accepts it" {
    start_openhim "$NAME" openhim,backups
    timeout 600 "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    timeout 300 "$BIN/pihx" "$NAME" wait >/dev/null 2>&1
    mongo_eval "$NAME" 'db.transactions.insertOne({_id: "drill-1", status: "Successful", request: {timestamp: new Date("2026-01-02T03:04:05Z")}})' >/dev/null
    # Nothing writes to the database between the backup and the summary (openhim-core records metrics).
    docker stop "$NAME-openhim-core" >/dev/null

    run "$BIN/pihx" "$NAME" backup
    assert_success
    assert_output --partial 'openhim: done'
    refute_output --partial "$PW"
    run "$BIN/pihx" "$NAME" copy-backup latest --to=out
    assert_success
    run run_files out
    assert_output $'backup.log\nopenhim.archive.7z'
    # From the running mongo-db.
    "$BIN/pihx" "$NAME" summary --output=before.txt
    run cat before.txt
    assert_line '[openhim]'
    assert_line 'documents transactions 1'
    assert_line 'newest transaction 2026-01-02T03:04:05.000Z'

    start_openhim "$RESTORED" openhim
    ARCHIVE_PASSWORD="$PW" run timeout 600 "$BIN/pihx" "$RESTORED" initialize --from out
    assert_success
    assert_output --partial 'openhim: loading openhim.archive.7z into mongo-db'
    # Stopped: from a throwaway mongod on the restored volume, which it removes again.
    "$BIN/pihx" "$RESTORED" summary --output=after.txt
    run diff before.txt after.txt
    assert_success
    run docker ps -aq --filter "name=^$RESTORED-summary-"
    assert_output ''

    # The same admin password as the source's, so openhim-setup finds it set.
    timeout 600 "$BIN/pihx" "$RESTORED" start >/dev/null 2>&1
    run docker wait "$RESTORED-openhim-setup"
    assert_output 0
    run docker logs "$RESTORED-openhim-setup"
    assert_output --partial 'already matches OPENHIM_PASSWORD'
    run mongo_eval "$RESTORED" 'db.transactions.findOne({_id: "drill-1"}).status'
    assert_output Successful
}

# --- sqlserver --------------------------------------------------------------------------------------

sqlcmd_in() { # <name> <query>
    docker exec -e SQLCMDPASSWORD="$SA" "$1-sqlserver" /opt/mssql-tools18/bin/sqlcmd -C -S localhost \
        -U sa -b -h -1 -W -Q "SET NOCOUNT ON; $2"
}

create_sqlserver() { # <name> <services>
    SQLSERVER_SA_PASSWORD="$SA" SQLSERVER_PUBLISHED_PORT=0 SQLSERVER_DATABASES='d1 d2' \
        "$BIN/pihx" "$1" create --services="$2" >/dev/null
}

@test "sqlserver: nothing is backed up until databases are chosen; those restore with initialize" {
    create_sqlserver "$NAME" sqlserver,backups
    timeout 600 "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    timeout 300 "$BIN/pihx" "$NAME" wait >/dev/null 2>&1
    sqlcmd_in "$NAME" "USE d1; CREATE TABLE t (id INT, name NVARCHAR(20)); INSERT INTO t VALUES (1, N'drill');"

    # No database chosen: sqlserver is reported not backed up (and, as the only service, the run fails).
    run "$BIN/pihx" "$NAME" backup
    assert_failure
    assert_output --partial 'SQLSERVER_BACKUP_DATABASES is empty'
    assert_output --partial 'sqlserver: not backed up (its script wrote nothing)'
    run "$BIN/pihx" "$NAME" list-backups
    assert_output --partial 'Not backed up: sqlserver'

    set_env_value "$NAME" sqlserver SQLSERVER_BACKUP_DATABASES d1
    timeout 600 "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    run "$BIN/pihx" "$NAME" backup
    assert_success
    assert_output --partial 'sqlserver: backing up d1'
    assert_output --partial 'sqlserver: done'
    refute_output --partial "$SA"
    # The .bak is gone from the server's volume once archived.
    run docker exec "$NAME-sqlserver" ls -A /var/opt/mssql
    refute_output --partial '.backup-staging'
    run "$BIN/pihx" "$NAME" copy-backup latest --to=out
    assert_success
    run run_files out
    assert_output $'backup.log\nsqlserver.7z'
    # From the running server: only the chosen database.
    "$BIN/pihx" "$NAME" summary --output=before.txt
    run cat before.txt
    assert_output $'[sqlserver]\nrows d1.dbo.t 1'

    create_sqlserver "$RESTORED" sqlserver
    set_env_value "$RESTORED" sqlserver SQLSERVER_BACKUP_DATABASES d1
    ARCHIVE_PASSWORD="$PW" run timeout 600 "$BIN/pihx" "$RESTORED" initialize --from out
    assert_success
    assert_output --partial 'sqlserver: restoring d1'
    # Stopped: from a throwaway server on the restored volume, which it removes again.
    run timeout 300 "$BIN/pihx" "$RESTORED" summary --output=after.txt
    assert_success
    run diff before.txt after.txt
    assert_success
    run docker ps -aq --filter "name=^$RESTORED-summary-"
    assert_output ''
    timeout 600 "$BIN/pihx" "$RESTORED" start >/dev/null 2>&1
    timeout 300 "$BIN/pihx" "$RESTORED" wait >/dev/null 2>&1
    run sqlcmd_in "$RESTORED" "SELECT name FROM d1.dbo.t WHERE id = 1"
    assert_output drill
    # d2 wasn't chosen: sqlserver-setup created it empty on the first start.
    run sqlcmd_in "$RESTORED" "SELECT COUNT(*) FROM d2.sys.tables"
    assert_output 0
    run docker exec "$RESTORED-sqlserver" ls -A /var/opt/mssql
    refute_output --partial '.restore-staging'
}

@test "sqlserver: a database name that isn't one is refused before anything is backed up" {
    mkdir out
    run docker run --rm -v "$BATS_TEST_TMPDIR/out:/run-dir" \
        -v "$REPO_ROOT/services/sqlserver/scripts/backup.sh:/backup.sh:ro" \
        -e BACKUP_RUN_DIR=/run-dir -e ARCHIVE_PASSWORD="$PW" -e SQLCMDPASSWORD=x \
        -e SQLSERVER_BACKUP_DATABASES='d1 x];DROP' --entrypoint bash "$IMAGE" /backup.sh
    assert_failure
    assert_output --partial "'x];DROP' isn't a database name"
    run ls out
    assert_output ''
}
