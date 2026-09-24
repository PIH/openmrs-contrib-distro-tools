#!/usr/bin/env bats
# backup-openmrs-data-directory round trips: every output format restores (via extract-archive and
# via initialize) to exactly the original tree, and the safety checks hold.

load ../helpers

setup() {
    cd "$BATS_TEST_TMPDIR"
    make_data_fixture "$BATS_TEST_TMPDIR/data"
    write_tiny_dump dump.sql
}
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

backup() { # <output> [args...]
    "$UTILS/backup-openmrs-data-directory.sh" --volume="$BATS_TEST_TMPDIR/data" --output="$@"
}

# Extracts <archive> with extract-archive and checks the single top-level folder's name and tree.
assert_extracts_to() { # <archive> <expected folder name> <expected tree>
    # stdout only: it's the extracted path; progress goes to stderr.
    run --separate-stderr "$UTILS/extract-archive.sh" --path="$1" --output-dir="$BATS_TEST_TMPDIR/extracted"
    assert_success
    assert_equal "$(basename "$output")" "$2"
    run tree_of "$output"
    assert_output "$3"
}

# Runs initialize with RESTORE_OPENMRS_DATA_PATH=<source> and checks the resulting volume's tree --
# <expected tree> as backed up, so with openmrs-runtime.properties moved aside by initialize.
assert_initializes_to() { # <source> <expected tree> [VAR=value...]
    local src=$1 tree=$2; shift 2
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH="$src" "$@"
    assert_success
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "${tree/.\/openmrs-runtime.properties/./openmrs-runtime.properties.restored}"
}

env_file() { echo "$OPENMRS_DOCKER_HOME/$NAME/env"; }

# --- backup + extract-archive ----------------------------------------------------------------------

@test ".tar.gz holds the whole directory under a folder named after the archive" {
    backup malawi-data.tar.gz 2>/dev/null
    assert_extracts_to malawi-data.tar.gz malawi-data "$FIXTURE_TREE"
}

@test ".tgz holds the whole directory under a folder named after the archive" {
    backup site.tgz 2>/dev/null
    assert_extracts_to site.tgz site "$FIXTURE_TREE"
}

@test ".7z holds the whole directory, password-protected, under a folder named after the archive" {
    ARCHIVE_PASSWORD=pw backup nightly.7z >/dev/null 2>&1
    ARCHIVE_PASSWORD=pw assert_extracts_to nightly.7z nightly "$FIXTURE_TREE"
}

@test ".7z can't be extracted without its password" {
    ARCHIVE_PASSWORD=pw backup nightly.7z >/dev/null 2>&1
    ARCHIVE_PASSWORD=wrong run "$UTILS/extract-archive.sh" --path=nightly.7z --output-dir="$BATS_TEST_TMPDIR/extracted"
    assert_failure
}

@test ".7z output is owned by the user who ran the backup" {
    ARCHIVE_PASSWORD=pw backup nightly.7z >/dev/null 2>&1
    assert_equal "$(stat -c %u nightly.7z)" "$(id -u)"
}

@test "--exclude-distribution-artifacts empties modules, owa, configuration and frontend (.tar.gz)" {
    backup lean.tar.gz --exclude-distribution-artifacts 2>/dev/null
    assert_extracts_to lean.tar.gz lean "$FIXTURE_TREE_EXCLUDED"
}

@test "--exclude-distribution-artifacts empties modules, owa, configuration and frontend (.7z)" {
    ARCHIVE_PASSWORD=pw backup lean.7z --exclude-distribution-artifacts >/dev/null 2>&1
    ARCHIVE_PASSWORD=pw assert_extracts_to lean.7z lean "$FIXTURE_TREE_EXCLUDED"
}

@test "backs up a named Docker volume" {
    local vol
    vol="$(res data)"
    docker volume create "$vol" >/dev/null
    docker run --rm -v "$vol:/v" -v "$BATS_TEST_TMPDIR/data:/src:ro" alpine:3.21 cp -a /src/. /v/
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$vol" --output=vol.tar.gz
    assert_success
    assert_extracts_to vol.tar.gz vol "$FIXTURE_TREE"
}

@test "an archive named after a system directory still holds the data (etc.tar.gz)" {
    backup etc.tar.gz 2>/dev/null
    assert_extracts_to etc.tar.gz etc "$FIXTURE_TREE"
}

@test "refuses while a running container has the named volume mounted" {
    local vol
    vol="$(res data)"
    docker volume create "$vol" >/dev/null
    docker run -d --name "$(res user)" -v "$vol:/openmrs/data" alpine:3.21 sleep 300 >/dev/null
    run "$UTILS/backup-openmrs-data-directory.sh" --volume="$vol" --output=out.tar.gz
    assert_failure
    assert_output --partial 'in use by a running container'
    assert [ ! -e out.tar.gz ]
}

@test "refuses while a running container has the host directory bind-mounted" {
    docker run -d --name "$(res user)" -v "$BATS_TEST_TMPDIR/data:/openmrs/data" alpine:3.21 sleep 300 >/dev/null
    run backup out.tar.gz
    assert_failure
    assert_output --partial 'in use by a running container'
    assert [ ! -e out.tar.gz ]
}

@test "--allow-running backs up anyway, with a warning" {
    docker run -d --name "$(res user)" -v "$BATS_TEST_TMPDIR/data:/openmrs/data" alpine:3.21 sleep 300 >/dev/null
    run backup out.tar.gz --allow-running
    assert_success
    assert_output --partial 'warning:'
    assert_extracts_to out.tar.gz out "$FIXTURE_TREE"
}

@test "ARCHIVE_PASSWORD never appears in a docker command line" {
    record_docker_argv
    ARCHIVE_PASSWORD=s3cret-archive-pw backup nightly.7z >/dev/null 2>&1
    ARCHIVE_PASSWORD=s3cret-archive-pw "$UTILS/extract-archive.sh" --path=nightly.7z --output-dir="$BATS_TEST_TMPDIR/x" >/dev/null 2>&1
    assert_not_in_docker_argv s3cret-archive-pw
}

# --- initialize RESTORE_OPENMRS_DATA_PATH ----------------------------------------------------------

@test "initialize restores openmrs-data from a .tar.gz backup" {
    backup data.tar.gz 2>/dev/null
    assert_initializes_to data.tar.gz "$FIXTURE_TREE"
}

@test "initialize restores openmrs-data from a .7z backup" {
    ARCHIVE_PASSWORD=pw backup data.7z >/dev/null 2>&1
    assert_initializes_to data.7z "$FIXTURE_TREE" ARCHIVE_PASSWORD=pw
}

@test "initialize restores openmrs-data from an --exclude-distribution-artifacts backup" {
    backup lean.tgz --exclude-distribution-artifacts 2>/dev/null
    assert_initializes_to lean.tgz "$FIXTURE_TREE_EXCLUDED"
}

@test "initialize restores openmrs-data from a plain directory" {
    assert_initializes_to "$BATS_TEST_TMPDIR/data" "$FIXTURE_TREE"
}

@test "initialize restores openmrs-data from a flat (seed-style) archive with no top-level folder" {
    tar czf flat.tar.gz -C data .
    assert_initializes_to flat.tar.gz "$FIXTURE_TREE"
}

@test "initialize with a wrong .7z password fails, shows why, and leaves no containers" {
    ARCHIVE_PASSWORD=pw backup data.7z >/dev/null 2>&1
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH=data.7z ARCHIVE_PASSWORD=wrong
    assert_failure
    assert_output --partial 'Wrong password'
    assert_equal "$(docker ps -aq --filter "name=^$NAME")" ""
}

@test "initialize never puts ARCHIVE_PASSWORD in a docker command line" {
    ARCHIVE_PASSWORD=s3cret-restore-pw backup data.7z >/dev/null 2>&1
    record_docker_argv
    assert_initializes_to data.7z "$FIXTURE_TREE" ARCHIVE_PASSWORD=s3cret-restore-pw
    assert_not_in_docker_argv s3cret-restore-pw
}

@test "initialize moves a restored openmrs-runtime.properties aside, contents intact" {
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH="$BATS_TEST_TMPDIR/data"
    assert_success
    assert_output --partial 'Moved restored openmrs-runtime.properties aside'
    run docker run --rm -v "${NAME}_openmrs-data:/v" alpine:3.21 cat /v/openmrs-runtime.properties.restored
    assert_output 'connection.url=jdbc:mysql://x/openmrs'
}

@test "initialize sets OPENMRS_CREATE_TABLES=false after restoring openmrs-data" {
    assert_initializes_to "$BATS_TEST_TMPDIR/data" "$FIXTURE_TREE"
    run grep '^OPENMRS_CREATE_TABLES=' "$(env_file)"
    assert_output 'OPENMRS_CREATE_TABLES=false'
}

@test "initialize sets OPENMRS_CREATE_TABLES=false when openmrs-data is neither restored nor seeded" {
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_success
    run grep '^OPENMRS_CREATE_TABLES=' "$(env_file)"
    assert_output 'OPENMRS_CREATE_TABLES=false'
}

@test "initialize keeps an OPENMRS_CREATE_TABLES already in the env file" {
    NAME="$(instance)"
    create_instance "$NAME"
    echo 'OPENMRS_CREATE_TABLES=true' >> "$(env_file)"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH="$BATS_TEST_TMPDIR/data"
    assert_success
    run grep '^OPENMRS_CREATE_TABLES=' "$(env_file)"
    assert_output 'OPENMRS_CREATE_TABLES=true'
}

@test "initialize with a failed restore leaves OPENMRS_CREATE_TABLES unset" {
    ARCHIVE_PASSWORD=pw backup data.7z >/dev/null 2>&1
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql RESTORE_OPENMRS_DATA_PATH=data.7z ARCHIVE_PASSWORD=wrong
    assert_failure
    run grep '^OPENMRS_CREATE_TABLES=' "$(env_file)"
    assert_failure
}
