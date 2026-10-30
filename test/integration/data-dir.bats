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

# Runs initialize --from a folder with the dump and <source> as its <entry> (openmrs, or
# openmrs.<archive extension>) and checks the resulting volume's tree -- <expected tree> as backed
# up, so with openmrs-runtime.properties moved aside by initialize.
assert_initializes_to() { # <entry> <source> <expected tree>
    local entry=$1 src=$2 tree=$3
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql "$entry" "$src")"
    assert_success
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "${tree/.\/openmrs-runtime.properties/./openmrs-runtime.properties.restored}"
}

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

@test "--exclude-distribution-artifacts empties modules, owa, configuration and frontend, drops .openmrs-lib-cache (.tar.gz)" {
    backup lean.tar.gz --exclude-distribution-artifacts 2>/dev/null
    assert_extracts_to lean.tar.gz lean "$FIXTURE_TREE_EXCLUDED"
}

@test "--exclude-distribution-artifacts empties modules, owa, configuration and frontend, drops .openmrs-lib-cache (.7z)" {
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

@test "refuses a data directory holding a symbolic link, naming it and where it points (.7z)" {
    # As found on a legacy server: a link back to the data directory by its absolute host path.
    ln -s /home/tomcat/.OpenMRS "$BATS_TEST_TMPDIR/data/openmrs"
    ARCHIVE_PASSWORD=pw run backup out.7z
    assert_failure
    assert_output --partial 'error: symbolic links'
    assert_output --partial 'openmrs -> /home/tomcat/.OpenMRS'
    assert [ ! -e out.7z ]
}

@test "refuses a data directory holding a symbolic link, naming it and where it points (.tar.gz)" {
    ln -s ../complex_obs/../../x "$BATS_TEST_TMPDIR/data/.hidden/img"
    run backup out.tar.gz
    assert_failure
    assert_output --partial '.hidden/img -> ../complex_obs/../../x'
    assert [ ! -e out.tar.gz ]
}

@test "backs up symbolic links within the data directory as links (.tar.gz, .7z)" {
    # As in a distro's configuration: one file linked to another beside it.
    ln -s h.csv "$BATS_TEST_TMPDIR/data/configuration/addresshierarchy/h-site.csv"
    ln -s ../complex_obs/./1.jpg "$BATS_TEST_TMPDIR/data/.hidden/img"
    for out in linked.tar.gz linked.7z; do
        ARCHIVE_PASSWORD=pw backup "$out" >/dev/null 2>&1
        ARCHIVE_PASSWORD=pw run --separate-stderr "$UTILS/extract-archive.sh" --path="$out" \
            --output-dir="$BATS_TEST_TMPDIR/extracted-$out"
        assert_success
        assert_equal "$(readlink "$output/configuration/addresshierarchy/h-site.csv")" h.csv
        assert_equal "$(readlink "$output/.hidden/img")" ../complex_obs/./1.jpg
    done
}

@test "--exclude-distribution-artifacts ignores symbolic links in what it leaves out" {
    ln -s /nowhere "$BATS_TEST_TMPDIR/data/modules/linked.omod"
    ln -s /nowhere "$BATS_TEST_TMPDIR/data/.openmrs-lib-cache/linked"
    ARCHIVE_PASSWORD=pw backup lean.7z --exclude-distribution-artifacts >/dev/null 2>&1
    ARCHIVE_PASSWORD=pw assert_extracts_to lean.7z lean "$FIXTURE_TREE_EXCLUDED"
}

# The fixture with links to an image's config, as in a Bahmni image's data directory (recreated on
# every start), backed up leaving them out with --exclude, as well as a folder and a file.
backup_excluding() { # <output>
    ln -s /var/www/config/calc "$BATS_TEST_TMPDIR/data/calc"
    mkdir -p "$BATS_TEST_TMPDIR/data/home/.OpenMRS"
    ln -s /opt/openmrs/modules "$BATS_TEST_TMPDIR/data/home/.OpenMRS/modules"
    ARCHIVE_PASSWORD=pw run backup "$1" --exclude=calc --exclude=home/.OpenMRS/modules/ \
        --exclude=.hidden --exclude=complex_obs/1.jpg
    assert_success
}
FIXTURE_TREE_EXCLUDING="./.openmrs-lib-cache
./.openmrs-lib-cache/c.class
./complex_obs
./configuration
./configuration/addresshierarchy
./configuration/addresshierarchy/h.csv
./frontend
./frontend/f.js
./home
./home/.OpenMRS
./modules
./modules/a.omod
./openmrs-runtime.properties
./owa
./owa/app.zip"

@test "--exclude leaves out files, folders and links, which the link check then ignores (.tar.gz)" {
    backup_excluding lean.tar.gz
    assert_extracts_to lean.tar.gz lean "$FIXTURE_TREE_EXCLUDING"
}

@test "--exclude leaves out files, folders and links, which the link check then ignores (.7z)" {
    backup_excluding lean.7z
    ARCHIVE_PASSWORD=pw assert_extracts_to lean.7z lean "$FIXTURE_TREE_EXCLUDING"
}

@test "--exclude still refuses the outside links it doesn't leave out" {
    ln -s /var/www/config/calc "$BATS_TEST_TMPDIR/data/calc"
    ln -s /opt/openmrs/x.properties "$BATS_TEST_TMPDIR/data/x.properties"
    run backup out.tar.gz --exclude=calc
    assert_failure
    assert_output --partial 'x.properties -> /opt/openmrs/x.properties'
    refute_output --partial 'calc ->'
    assert [ ! -e out.tar.gz ]
}

@test "ARCHIVE_PASSWORD never appears in a docker command line" {
    record_docker_argv
    ARCHIVE_PASSWORD=s3cret-archive-pw backup nightly.7z >/dev/null 2>&1
    ARCHIVE_PASSWORD=s3cret-archive-pw "$UTILS/extract-archive.sh" --path=nightly.7z --output-dir="$BATS_TEST_TMPDIR/x" >/dev/null 2>&1
    assert_not_in_docker_argv s3cret-archive-pw
}

# --- initialize --from: openmrs-data -------------------------------------------------------------

@test "initialize restores openmrs-data from a .tar.gz backup" {
    backup data.tar.gz 2>/dev/null
    assert_initializes_to openmrs.tar.gz data.tar.gz "$FIXTURE_TREE"
}

@test "initialize restores openmrs-data from a .7z backup" {
    ARCHIVE_PASSWORD=pw backup data.7z >/dev/null 2>&1
    ARCHIVE_PASSWORD=pw assert_initializes_to openmrs.7z data.7z "$FIXTURE_TREE"
}

@test "initialize restores openmrs-data from an --exclude-distribution-artifacts backup" {
    backup lean.tgz --exclude-distribution-artifacts 2>/dev/null
    assert_initializes_to openmrs.tgz lean.tgz "$FIXTURE_TREE_EXCLUDED"
}

@test "initialize restores openmrs-data from a plain directory" {
    assert_initializes_to openmrs "$BATS_TEST_TMPDIR/data" "$FIXTURE_TREE"
}

@test "initialize restores openmrs-data from a flat (seed-style) archive with no top-level folder" {
    tar czf flat.tar.gz -C data .
    assert_initializes_to openmrs.tar.gz flat.tar.gz "$FIXTURE_TREE"
}

@test "initialize with a wrong .7z password fails, shows why, and leaves no containers" {
    ARCHIVE_PASSWORD=pw backup data.7z >/dev/null 2>&1
    NAME="$(instance)"
    create_instance "$NAME"
    ARCHIVE_PASSWORD=wrong run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs.7z data.7z)"
    assert_failure
    assert_output --partial 'Wrong password'
    assert_equal "$(docker ps -aq --filter "name=^$NAME")" ""
}

@test "initialize never puts ARCHIVE_PASSWORD in a docker command line" {
    ARCHIVE_PASSWORD=s3cret-restore-pw backup data.7z >/dev/null 2>&1
    record_docker_argv
    ARCHIVE_PASSWORD=s3cret-restore-pw assert_initializes_to openmrs.7z data.7z "$FIXTURE_TREE"
    assert_not_in_docker_argv s3cret-restore-pw
}

@test "initialize moves a restored openmrs-runtime.properties aside, contents intact" {
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs data)"
    assert_success
    assert_output --partial 'Moved openmrs-runtime.properties aside'
    run docker run --rm -v "${NAME}_openmrs-data:/v" alpine:3.21 cat /v/openmrs-runtime.properties.restored
    assert_output 'connection.url=jdbc:mysql://x/openmrs'
}

# OpenMRS creates its tables only when a pihx start has just found the database empty
# (services/openmrs/start/create-tables): a plain `docker compose` gets false, unless
# OPENMRS_CREATE_TABLES says otherwise. Nothing is recorded in the instance's files.
create_tables_setting() { # what the openmrs container gets
    instance_compose_of "$NAME" config --format json | jq -r '.services.openmrs.environment.OMRS_CONFIG_CREATE_TABLES'
}

@test "initialize records nothing about the tables, and a plain docker compose doesn't create them" {
    assert_initializes_to openmrs "$BATS_TEST_TMPDIR/data" "$FIXTURE_TREE"
    run grep 'CREATE_TABLES\|CREATED_EMPTY\|FOUND_EMPTY' "$PIHX_HOME/$NAME"/*.env
    assert_failure
    run create_tables_setting
    assert_output false
}

@test "OPENMRS_CREATE_TABLES in openmrs.env decides" {
    NAME="$(instance)"
    create_instance "$NAME"
    echo 'OPENMRS_CREATE_TABLES=true' >> "$(env_file_of "$NAME" openmrs)"
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs data)"
    assert_success
    run grep '^OPENMRS_CREATE_TABLES=' "$(env_file_of "$NAME" openmrs)"
    assert_output 'OPENMRS_CREATE_TABLES=true'
    run create_tables_setting
    assert_output true
}

# --- initialize: ownership of a restored openmrs-data ----------------------------------------------

# Prints every entry in <volume> whose owner isn't <uid>:<gid>.
not_owned_by() { # <volume> <uid> <gid>
    docker run --rm -v "$1:/d:ro" alpine:3.21 find /d \( ! -user "$2" -o ! -group "$3" \)
}

@test "initialize gives a restored openmrs-data to OPENMRS_DATA_OWNER" {
    backup data.tar.gz 2>/dev/null
    NAME="$(instance)"
    create_instance "$NAME"
    OPENMRS_DATA_OWNER=1234:5678 run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs.tar.gz data.tar.gz)"
    assert_success
    assert_output --partial 'Changed the owner of the restored openmrs-data to 1234:5678'
    run not_owned_by "${NAME}_openmrs-data" 1234 5678
    assert_success
    assert_output ''
}

@test "initialize reads the restored openmrs-data's owner from the openmrs image when OPENMRS_DATA_OWNER is unset" {
    NAME="$(instance)"
    OPENMRS_IMAGE_NAME=alpine OPENMRS_IMAGE_TAG=3.21 create_instance "$NAME"
    OPENMRS_DATA_OWNER= run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs data)"
    assert_success
    assert_output --partial 'Changed the owner of the restored openmrs-data to 0:0'
    run not_owned_by "${NAME}_openmrs-data" 0 0
    assert_output ''
}

@test "initialize fails before creating any volume when the openmrs image can't be run to find the owner" {
    NAME="$(instance)"
    create_instance "$NAME"
    OPENMRS_DATA_OWNER= run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs data)"
    assert_failure
    assert_output --partial 'set OPENMRS_DATA_OWNER'
    assert_equal "$(docker volume ls -q --filter "name=^${NAME}_")" ""
}

@test "initialize restores openmrs-data from a directory the operator can't enter" {
    chmod 000 "$BATS_TEST_TMPDIR/data"
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs data)"
    chmod 755 "$BATS_TEST_TMPDIR/data"
    assert_success
    run tree_of_volume "${NAME}_openmrs-data"
    assert_output "${FIXTURE_TREE/.\/openmrs-runtime.properties/./openmrs-runtime.properties.restored}"
}

@test "initialize failing after the restore removes what it made, so it can be retried without a destroy" {
    NAME="$(instance)"
    create_instance "$NAME"
    OPENMRS_DATA_OWNER=no-such-user:no-such-group \
        run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs data)"
    assert_failure
    assert_output --partial "initialize failed"
    assert_equal "$(docker volume ls -q --filter "name=^${NAME}_")" ""
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql openmrs data)"
    assert_success
}

@test "ARCHIVE_PASSWORD never appears in any process's command line, in or out of containers" {
    # enough data that 7z runs long enough to be seen
    head -c 30000000 /dev/urandom > "$BATS_TEST_TMPDIR/data/complex_obs/big.bin"
    ARCHIVE_PASSWORD=s3cret-ps-archive assert_not_in_ps_while s3cret-ps-archive backup nightly.7z
    ARCHIVE_PASSWORD=s3cret-ps-archive assert_not_in_ps_while s3cret-ps-archive \
        "$UTILS/extract-archive.sh" --path=nightly.7z --output-dir="$BATS_TEST_TMPDIR/x"
    NAME="$(instance)"
    create_instance "$NAME"
    ARCHIVE_PASSWORD=s3cret-ps-archive assert_not_in_ps_while s3cret-ps-archive "$BIN/openmrs-docker" \
        "$NAME" initialize --from "$(from_folder openmrs-db.sql dump.sql openmrs.7z nightly.7z)"
    run docker run --rm -v "${NAME}_openmrs-data:/d:ro" alpine:3.21 stat -c %s /d/complex_obs/big.bin
    assert_output 30000000
}
