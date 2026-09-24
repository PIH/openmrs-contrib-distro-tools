#!/usr/bin/env bats
# backup-mysqldump round trips: every output format restores through initialize to the original
# data, and secrets stay out of command lines.

load ../helpers

setup_file() {
    export SRC_DB="$RUN_PREFIX-f-dumpsrc"
    start_source_db "$SRC_DB"
    # A trigger whose DEFINER account won't exist on any restore target: it restores, but fails the
    # moment it fires -- exactly what strip-mysqldump-definers exists to fix.
    mysql_exec "$SRC_DB" openmrs "
        CREATE TABLE openmrs.audit (id INT) ENGINE=InnoDB;
        CREATE TABLE openmrs.audited (id INT) ENGINE=InnoDB;
        CREATE DEFINER='legacy'@'%' TRIGGER openmrs.audited_ins AFTER INSERT ON openmrs.audited
            FOR EACH ROW INSERT INTO openmrs.audit VALUES (NEW.id);
        CREATE USER 'dumper'@'%' IDENTIFIED BY 's3cret-mysql-pw';
        GRANT ALL PRIVILEGES ON *.* TO 'dumper'@'%';"
}
teardown_file() { common_teardown_file; }

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

dump() { # <output> [args...]
    MYSQL_PASSWORD=openmrs "$UTILS/backup-mysqldump.sh" --container="$SRC_DB" --output="$@"
}

# Lists the file names inside a .7z.
names_in_7z() { # <archive> <password>
    docker run --rm -v "$BATS_TEST_TMPDIR:/w:ro" partnersinhealth/p7zip \
        sh -c "7z l -slt -p'$2' '/w/$1' | sed -n 's/^Path = //p' | tail -n +2"
}

# Initializes a new instance from RESTORE_MYSQL_DUMP_PATH=<dump>.
initialize_from() { # <dump> [VAR=value...]
    local d=$1; shift
    NAME="$(instance)"
    create_instance "$NAME"
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH="$d" "$@"
}

# --- output formats --------------------------------------------------------------------------------

@test ".sql output is plain, uncompressed SQL" {
    dump out.sql 2>/dev/null
    run grep -c 'INSERT INTO `marker` VALUES (1)' out.sql
    assert_output 1
}

@test ".sql.gz output is gzip-compressed SQL" {
    dump out.sql.gz 2>/dev/null
    run gzip -t out.sql.gz
    assert_success
    run sh -c "zcat out.sql.gz | grep -c 'INSERT INTO \`marker\` VALUES (1)'"
    assert_output 1
}

@test ".sql.7z holds a single SQL file named after the archive" {
    ARCHIVE_PASSWORD=pw dump backup.sql.7z >/dev/null 2>&1
    run names_in_7z backup.sql.7z pw
    assert_output backup.sql
}

@test ".7z without .sql still names the SQL file inside <name>.sql" {
    ARCHIVE_PASSWORD=pw dump nightly.7z >/dev/null 2>&1
    run names_in_7z nightly.7z pw
    assert_output nightly.sql
}

@test ".7z output is owned by the user who ran the backup" {
    ARCHIVE_PASSWORD=pw dump backup.sql.7z >/dev/null 2>&1
    assert_equal "$(stat -c %u backup.sql.7z)" "$(id -u)"
}

@test "MYSQL_PASSWORD and ARCHIVE_PASSWORD never appear in a docker command line" {
    record_docker_argv
    run env MYSQL_PASSWORD=s3cret-mysql-pw ARCHIVE_PASSWORD=s3cret-dump-pw \
        "$UTILS/backup-mysqldump.sh" --container="$SRC_DB" --user=dumper --output=backup.sql.7z
    assert_success
    assert_not_in_docker_argv s3cret-mysql-pw
    assert_not_in_docker_argv s3cret-dump-pw
}

# --- restores --------------------------------------------------------------------------------------

@test "initialize restores a .sql dump" {
    dump out.sql 2>/dev/null
    initialize_from out.sql
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "initialize restores a .sql.gz dump" {
    dump out.sql.gz 2>/dev/null
    initialize_from out.sql.gz
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "initialize restores a .sql.7z dump after extract-archive" {
    ARCHIVE_PASSWORD=pw dump backup.sql.7z >/dev/null 2>&1
    local sql
    sql=$(ARCHIVE_PASSWORD=pw "$UTILS/extract-archive.sh" --path=backup.sql.7z --output-dir="$BATS_TEST_TMPDIR/x" 2>/dev/null)
    initialize_from "$sql"
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "initialize restores a .sql.7z dump directly" {
    ARCHIVE_PASSWORD=pw dump backup.sql.7z >/dev/null 2>&1
    initialize_from backup.sql.7z ARCHIVE_PASSWORD=pw
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "a .7z dump restore removes its temporary db-init volume afterwards" {
    ARCHIVE_PASSWORD=pw dump backup.sql.7z >/dev/null 2>&1
    initialize_from backup.sql.7z ARCHIVE_PASSWORD=pw
    assert_success
    run docker volume inspect "${NAME}_db-init"
    assert_failure
}

@test "initialize never puts a .7z dump's ARCHIVE_PASSWORD in a docker command line" {
    ARCHIVE_PASSWORD=s3cret-dumparchive-pw dump backup.sql.7z >/dev/null 2>&1
    record_docker_argv
    initialize_from backup.sql.7z ARCHIVE_PASSWORD=s3cret-dumparchive-pw
    assert_success
    assert_not_in_docker_argv s3cret-dumparchive-pw
}

@test "initialize restores a .sql.gz dump wrapped in a .7z directly" {
    dump inner.sql.gz 2>/dev/null
    docker run --rm -v "$BATS_TEST_TMPDIR:/w" partnersinhealth/p7zip \
        7z a -ppw -t7z /w/legacy.sql.gz.7z /w/inner.sql.gz >/dev/null
    initialize_from legacy.sql.gz.7z ARCHIVE_PASSWORD=pw
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}

@test "initialize with a wrong password for a .7z dump fails and shows why" {
    ARCHIVE_PASSWORD=pw dump backup.sql.7z >/dev/null 2>&1
    initialize_from backup.sql.7z ARCHIVE_PASSWORD=wrong
    assert_failure
    assert_output --partial 'Wrong password'
    assert_equal "$(docker ps -aq --filter "name=^$NAME")" ""
}

@test "a dump of a differently named database restores into the instance's openmrs database" {
    dump malawi.sql --database=malawi 2>/dev/null
    initialize_from malawi.sql
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 2
}

@test "a dump stripped of DEFINERs restores triggers that still fire" {
    dump out.sql.gz 2>/dev/null
    "$UTILS/strip-mysqldump-definers.sh" --path=out.sql.gz --output=stripped.sql.gz 2>/dev/null
    initialize_from stripped.sql.gz
    assert_success
    run db_query_in_volume "${NAME}_db-data" 'INSERT INTO audited VALUES (7); SELECT id FROM audit;'
    assert_output 7
}

@test "--strip-definers writes a dump with no DEFINER clauses whose triggers still fire" {
    dump out.sql --strip-definers 2>/dev/null
    run grep -c 'DEFINER=' out.sql
    assert_output 0
    initialize_from out.sql
    assert_success
    run db_query_in_volume "${NAME}_db-data" 'INSERT INTO audited VALUES (8); SELECT id FROM audit;'
    assert_output 8
}

@test "--strip-definers also applies to a .7z dump" {
    ARCHIVE_PASSWORD=pw dump backup.sql.7z --strip-definers >/dev/null 2>&1
    initialize_from backup.sql.7z ARCHIVE_PASSWORD=pw
    assert_success
    run db_query_in_volume "${NAME}_db-data" 'INSERT INTO audited VALUES (9); SELECT id FROM audit;'
    assert_output 9
}

@test "--host dumps over TCP, for a MySQL that isn't in a container" {
    local ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SRC_DB")
    MYSQL_PASSWORD=openmrs "$UTILS/backup-mysqldump.sh" --host="$ip" --port=3306 --output=out.sql 2>/dev/null
    initialize_from out.sql
    assert_success
    run db_marker_in_volume "${NAME}_db-data"
    assert_output 1
}
