#!/usr/bin/env bats
# initialize RESTORE_MYSQL_PERCONA_PATH restores a Percona/xtrabackup backup in containers: from a
# .7z like the legacy nightly percona.7z (which backup-percona --output=<.7z> also writes), a
# folder-wrapped .tar.gz, or an unprepared directory. backup-percona --host backs up a MySQL that
# isn't in a container.

load ../helpers

setup_file() {
    export SRC_DB="$(file_res src)"
    start_source_db "$SRC_DB"
}
teardown_file() { common_teardown_file; }

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

percona_backup() { # <output> [args...]
    local out=$1; shift
    MYSQL_PASSWORD=openmrs "$UTILS/backup-percona.sh" --container="$SRC_DB" --volume="$SRC_DB-data" --output="$out" "$@"
}

restore_percona() { # <path> [VAR=value...]
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    local path=$1; shift
    run_initialize "$NAME" RESTORE_MYSQL_PERCONA_PATH="$path" "$@"
}

in_7z() { # <archive> <password> <7z args...>
    local archive=$1 pw=$2; shift 2
    docker run --rm -v "$(cd "$(dirname "$archive")" && pwd):/w" "$P7ZIP_IMAGE" 7z "$@" -p"$pw" "/w/$(basename "$archive")"
}

@test "backup-percona --output=<.7z> writes the legacy layout, and initialize restores it" {
    record_docker_argv
    ARCHIVE_PASSWORD=pw run percona_backup backup.7z
    assert_success
    # its temporary volume is gone (named from the recorded command line: other test files make their own)
    local tmp_volume
    tmp_volume=$(sed -n 's/^volume create \(backup-percona-[^ ]*\)$/\1/p' "$DOCKER_ARGV_LOG")
    [ -n "$tmp_volume" ]
    run docker volume inspect "$tmp_volume"
    assert_failure
    # prepared, with the backup's files at the top level
    run in_7z backup.7z pw l -ba -slt
    assert_line 'Path = xtrabackup_checkpoints'
    refute_line --regexp '^Path = .*/xtrabackup_checkpoints$'
    run in_7z backup.7z wrong t
    assert_failure
    ARCHIVE_PASSWORD=pw restore_percona backup.7z
    assert_success
    assert_output --partial "Set the password of openmrs@%"
    refute_output --partial "Preparing the backup"
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
    run docker volume inspect "${NAME}_percona-staging"
    assert_failure
}

@test "an unprepared backup directory is prepared first" {
    mkdir raw
    docker run --rm --network "container:$SRC_DB" -e MYSQL_PWD=openmrs -v "$SRC_DB-data:/var/lib/mysql:ro" \
        -v "$BATS_TEST_TMPDIR/raw:/backup" "$PERCONA_IMAGE" \
        sh -c 'innobackupex --user=root --password="$MYSQL_PWD" --host=127.0.0.1 --no-timestamp /backup/b' >/dev/null 2>&1
    run docker run --rm -v "$BATS_TEST_TMPDIR/raw:/r:ro" alpine:3.21 grep -c 'backup_type = full-backuped' /r/b/xtrabackup_checkpoints
    assert_output 1
    restore_percona raw/b
    assert_success
    assert_output --partial "Preparing the backup"
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "a .tar.gz holding one <name>-percona folder restores" {
    percona_backup site-percona >/dev/null 2>&1
    tar czf site-percona.tar.gz site-percona
    restore_percona site-percona.tar.gz
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "an archive that isn't a Percona backup is refused, and nothing is left behind" {
    mkdir -p notpercona && echo x > notpercona/f
    tar czf notpercona.tar.gz notpercona
    restore_percona notpercona.tar.gz
    assert_failure
    assert_output --partial "isn't a Percona/xtrabackup backup"
    destroy_instance "$NAME"; NAME=
    assert_no_leftovers
}

@test "backup-percona --host backs up a MySQL that isn't in a container" {
    local db port
    db=$(res hostdb)
    mkdir datadir
    docker run -d --name "$db" -p 127.0.0.1::3306 -v "$BATS_TEST_TMPDIR/datadir:/var/lib/mysql" \
        -e MYSQL_ROOT_PASSWORD=openmrs -e MYSQL_DATABASE=openmrs "$MYSQL_IMAGE" >/dev/null
    wait_for_mysql "$db" root openmrs
    mysql_exec "$db" openmrs 'CREATE TABLE openmrs.marker (id INT) ENGINE=InnoDB; INSERT INTO openmrs.marker VALUES (7);'
    port=$(docker port "$db" 3306 | head -1 | cut -d: -f2)
    MYSQL_PASSWORD=openmrs ARCHIVE_PASSWORD=pw run "$UTILS/backup-percona.sh" \
        --host=127.0.0.1 --port="$port" --volume="$BATS_TEST_TMPDIR/datadir" --output=host.7z
    assert_success
    ARCHIVE_PASSWORD=pw restore_percona host.7z
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 7
}
