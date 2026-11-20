#!/usr/bin/env bats
# The backups service on an instance, black-box through bin/pihx: backup, list-backups, copy-backup,
# a run restoring into a new instance with initialize --from, and destroy keeping the backups volume.
# OpenMRS is the stub image (it sleeps); openmrs-db is real.

load ../helpers

setup_file() {
    build_stub_openmrs_image
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    RESTORED="$(instance restored)"
    export OPENMRS_IMAGE_NAME="$STUB_OPENMRS_IMAGE" OPENMRS_IMAGE_TAG=latest OPENMRS_HTTP_PORT=0 \
        BACKUP_ARCHIVE_PASSWORD=Backup-pw-1
}
teardown() {
    remove_test_instance "$NAME"
    remove_test_instance "$RESTORED"
    common_teardown
}

# The instance <name> with openmrs-db, openmrs and backups, filled from a tiny dump and the data
# fixture (with an extra directory to leave out), and started.
start_backed_up_instance() { # <name>
    mkdir -p run
    write_tiny_dump run/openmrs-db.sql
    make_data_fixture run/openmrs
    mkdir -p run/openmrs/skip && echo s > run/openmrs/skip/s.txt
    "$BIN/pihx" "$1" create --services=openmrs-db,openmrs,backups >/dev/null
    set_env_value "$1" openmrs OPENMRS_DATA_BACKUP_EXCLUDES 'skip missing'
    timeout 300 "$BIN/pihx" "$1" initialize --from run >/dev/null 2>&1
    "$BIN/pihx" "$1" start >/dev/null 2>&1
}

@test "a backup run copied out restores into a new instance" {
    start_backed_up_instance "$NAME"
    # The schedule runs in the container (supercronic), in the instance's TZ.
    run docker logs "$NAME-backups"
    assert_output --partial "backup schedule '30 1 * * *', upload schedule '15 * * * *' (TZ UTC)"

    run "$BIN/pihx" "$NAME" backup
    assert_success
    assert_output --partial 'openmrs-db: done'
    assert_output --partial 'openmrs: done'
    assert_output --regexp "backup ${NAME}_[0-9]{8}T[0-9]{6}Z success"
    refute_output --partial "$BACKUP_ARCHIVE_PASSWORD"

    run "$BIN/pihx" "$NAME" list-backups
    assert_success
    assert_line --regexp "^${NAME}_[0-9]{8}T[0-9]{6}Z +complete +[0-9.]+[KMG] +no$"
    assert_output --partial 'Backup: last success at'
    assert_output --partial 'Upload: never run'
    refute_output --partial 'Not backed up'

    run "$BIN/pihx" "$NAME" upload-backups
    assert_success
    assert_output --partial "Uploads aren't configured for $NAME"

    run "$BIN/pihx" "$NAME" copy-backup latest --to=out
    assert_success
    assert_output --partial "initialize --from $BATS_TEST_TMPDIR/out"
    run ls out
    assert_output $'backup.log\nopenmrs-db.sql.7z\nopenmrs.7z'
    # The caller's, like everything pihx writes on the host.
    run find out -not -user "$(id -u)"
    assert_output ''

    # The run directory restores as it is (its backup.log is ignored).
    "$BIN/pihx" "$RESTORED" create --services=openmrs-db,openmrs >/dev/null
    ARCHIVE_PASSWORD="$BACKUP_ARCHIVE_PASSWORD" run timeout 300 "$BIN/pihx" "$RESTORED" initialize --from out
    assert_success
    run db_marker_in_volume "${RESTORED}_db-data"
    assert_output 1
    run tree_of_volume "${RESTORED}_openmrs-data"
    assert_line ./complex_obs/1.jpg
    assert_line ./.hidden/h
    # The distribution artifacts' contents and the excluded directory are left out.
    refute_line ./modules/a.omod
    refute_line ./skip/s.txt
    assert_line ./modules
}

@test "copy-backup refuses a run that isn't complete, and backup needs the service running" {
    start_backed_up_instance "$NAME"
    "$BIN/pihx" "$NAME" stop >/dev/null 2>&1
    run "$BIN/pihx" "$NAME" backup
    assert_failure
    assert_output --partial "backups container isn't running: start $NAME first"
    run "$BIN/pihx" "$NAME" copy-backup latest --to=out
    assert_failure
    assert_output --partial "has no complete backup run yet"
    # The directory the launcher made for it goes again.
    [ ! -e out ]
}

@test "destroy keeps the backups volume, and --include-backups archives and removes it" {
    start_backed_up_instance "$NAME"
    "$BIN/pihx" "$NAME" backup >/dev/null 2>&1
    run_destroy "$BIN/pihx" "$NAME"
    assert_success
    assert_output --partial "It keeps ${NAME}_backups"
    run docker volume ls -q --filter "name=^${NAME}_"
    assert_output "${NAME}_backups"
    local archive
    archive=$(ls -d "$PIHX_HOME/$NAME".destroyed-*)
    [ ! -e "$archive/${NAME}_backups.tar.gz" ]
    reclaim "$archive" && rm -rf "$archive"

    # Created again, the instance's backups volume (and its runs) are there.
    "$BIN/pihx" "$NAME" create --services=openmrs-db,openmrs,backups >/dev/null
    run "$BIN/pihx" "$NAME" list-backups
    assert_success
    assert_line --regexp "^${NAME}_[0-9]{8}T[0-9]{6}Z +complete"

    run bash -c 'printf "%s\ndelete\n" "$2" | "$1" "$2" destroy --include-backups' _ "$BIN/pihx" "$NAME"
    assert_success
    run docker volume ls -q --filter "name=^${NAME}_"
    assert_output ''
    archive=$(ls -d "$PIHX_HOME/$NAME".destroyed-*)
    [ -s "$archive/${NAME}_backups.tar.gz" ]
    reclaim "$archive" && rm -rf "$archive"
}
