#!/usr/bin/env bats
# The MySQL utilities work against MariaDB 11+, whose image has only the mariadb and mariadb-dump
# tools (no mysql or mysqldump).

load ../helpers

MARIADB_IMAGE=mariadb:11.4

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

# Starts a MariaDB container <name> on a volume <name>-data, with binary logging and an
# openmrs.marker row. Extra args go to `docker run`.
start_mariadb() { # <name> [docker run arg...]
    local name=$1 deadline=$(( $(date +%s) + 120 ))
    shift
    docker run -d --name "$name" -v "$name-data:/var/lib/mysql" "$@" \
        -e MARIADB_ROOT_PASSWORD=openmrs -e MARIADB_DATABASE=openmrs \
        -e MARIADB_USER=openmrs -e MARIADB_PASSWORD=openmrs \
        "$MARIADB_IMAGE" --log-bin=mysql-bin --server-id=1 >/dev/null
    until mariadb_exec "$name" 'SELECT 1' >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || { docker logs --tail 30 "$name" >&2; return 1; }
        sleep 2
    done
    mariadb_exec "$name" 'CREATE TABLE openmrs.marker (id INT) ENGINE=InnoDB; INSERT INTO openmrs.marker VALUES (1)'
}

mariadb_exec() { # <container> <sql>
    docker exec "$1" mariadb -h127.0.0.1 -uroot -popenmrs -N -e "$2"
}

@test "backup-mysqldump dumps a MariaDB, over --container and --host" {
    local db port
    db=$(res db)
    start_mariadb "$db" -p 127.0.0.1::3306
    port=$(docker port "$db" 3306 | head -1 | cut -d: -f2)
    MYSQL_PASSWORD=openmrs run "$UTILS/backup-mysqldump.sh" --container="$db" --output=c.sql
    assert_success
    run grep -c 'INSERT INTO `marker`' c.sql
    assert_output 1
    MYSQL_PASSWORD=openmrs run "$UTILS/backup-mysqldump.sh" --host=127.0.0.1 --port="$port" \
        --client-image="$MARIADB_IMAGE" --output=h.sql
    assert_success
    run grep -c 'INSERT INTO `marker`' h.sql
    assert_output 1
}

@test "purge-binlogs purges a MariaDB's binary logs" {
    local db
    db=$(res db)
    start_mariadb "$db"
    mariadb_exec "$db" 'FLUSH BINARY LOGS; FLUSH BINARY LOGS'
    MYSQL_PASSWORD=openmrs run "$UTILS/purge-binlogs.sh" --container="$db"
    assert_success
    assert_output --regexp 'after: +1 file\(s\)'
}

@test "fingerprint reads a running MariaDB and a stopped one's data directory the same" {
    local db
    db=$(res db)
    start_mariadb "$db"
    MYSQL_ROOT_PASSWORD=openmrs run "$UTILS/fingerprint.sh" --container="$db" --output=running.txt
    assert_success
    run cat running.txt
    assert_line 'openmrs.marker 1'
    assert_line --regexp '^version 11\.4\.'
    docker stop "$db" >/dev/null
    run "$UTILS/fingerprint.sh" --db-volume="$db-data" --image="$MARIADB_IMAGE" --output=stopped.txt
    assert_success
    run diff running.txt stopped.txt
    assert_success
}

@test "reset-mysql-accounts sets a MariaDB data directory's passwords" {
    local db
    db=$(res db)
    start_mariadb "$db"
    # Stopped cleanly: its server has binary logging on, and this one doesn't.
    docker stop "$db" >/dev/null && docker rm "$db" >/dev/null
    MYSQL_ROOT_PASSWORD=new-root MYSQL_PASSWORD=new-pw run "$UTILS/reset-mysql-accounts.sh" \
        --volume="$db-data" --image="$MARIADB_IMAGE"
    assert_success
    assert_output --partial "Set the password of openmrs@%"
    docker run -d --name "$db" -v "$db-data:/var/lib/mysql" "$MARIADB_IMAGE" >/dev/null
    local deadline=$(( $(date +%s) + 120 ))
    until docker exec "$db" mariadb -h127.0.0.1 -uopenmrs -pnew-pw -e 'SELECT 1' >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "can't log in as openmrs with the new password"
        sleep 2
    done
    run docker exec "$db" mariadb -h127.0.0.1 -uroot -pnew-root -N -e 'SELECT id FROM openmrs.marker'
    assert_output 1
}
