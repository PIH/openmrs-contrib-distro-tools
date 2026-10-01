#!/usr/bin/env bats
# Restores and backups refuse before writing anything when there's clearly not enough disk space
# (utils/lib/disk-space.sh). DISK_SPACE_FREE_KB stands in for a full disk; each case then checks
# what was estimated, and that nothing was created.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

random_file() { # <path> <KiB>
    mkdir -p "$(dirname "$1")" && head -c $(($2 * 1024)) /dev/urandom > "$1"
}

@test "initialize refuses before creating any volume, counting a .7z dump twice (extracted, then imported)" {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    random_file src/dump.sql 1024
    docker run --rm -v "$BATS_TEST_TMPDIR/src:/w" -w /w "$P7ZIP_IMAGE" 7z a -ppw /w/dump.7z dump.sql >/dev/null
    ARCHIVE_PASSWORD=pw DISK_SPACE_FREE_KB=100 run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=src/dump.7z
    assert_failure
    assert_output --partial "not enough disk space on Docker's volumes"
    assert_output --partial "needs about 2.0M"
    assert_no_leftovers
}

@test "initialize counts a .sql.gz dump at its uncompressed size, plus the openmrs-data directory" {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    random_file dump.sql 1024 && gzip dump.sql
    random_file data/complex_obs/a 1024
    DISK_SPACE_FREE_KB=100 run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql.gz RESTORE_OPENMRS_DATA_PATH=data
    assert_failure
    assert_output --regexp 'needs about 2\.0M'
    assert_no_leftovers
}

@test "backup-percona refuses before creating its output when the data directory won't fit" {
    local vol
    vol=$(res data)
    docker run --rm -v "$vol:/d" alpine:3.21 sh -c 'head -c 2097152 /dev/urandom > /d/ibdata1'
    MYSQL_PASSWORD=x DISK_SPACE_FREE_KB=100 run "$UTILS/backup-percona.sh" --container="$(res none)" --volume="$vol" --output=backup
    assert_failure
    assert_output --partial "a physical backup of $vol needs about 2.0M"
    [ ! -e backup ]
}

@test "convert-percona-backup refuses before creating its output when a full copy won't fit" {
    random_file backup/ibdata1 2048
    DISK_SPACE_FREE_KB=100 run "$UTILS/convert-percona-backup.sh" --backup-dir=backup --output-dir=datadir
    assert_failure
    assert_output --partial "needs about 2.0M"
    [ ! -e datadir ]
}

@test "backup-openmrs-data-directory refuses when the data won't fit, not counting what it leaves out" {
    random_file data/complex_obs/a 256
    random_file data/modules/big.omod 2048
    DISK_SPACE_FREE_KB=1000 run "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" --output=out.tar.gz
    assert_failure
    assert_output --partial "needs about 2."
    [ ! -e out.tar.gz ]
    DISK_SPACE_FREE_KB=1000 run "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" --output=out.tar.gz \
        --exclude-distribution-artifacts
    assert_success
    assert [ -f out.tar.gz ]
}

@test "initialize counts a Percona backup twice (extracted into a temporary volume, then copied in)" {
    NAME="$(instance)"
    SERVICES=openmrs-db create_instance "$NAME"
    random_file percona/ibdata1 1024
    DISK_SPACE_FREE_KB=100 run_initialize "$NAME" RESTORE_MYSQL_PERCONA_PATH=percona
    assert_failure
    assert_output --partial "needs about 2.0M"
    assert_no_leftovers
}
