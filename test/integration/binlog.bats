#!/usr/bin/env bats
# openmrs-db's binary logging switch: off by default, expiry when on, and purge-binlogs for turning
# it off without leaving binlogs on disk.

load ../helpers

teardown() {
    local name
    name="$(instance)"
    [ -d "$OPENMRS_DOCKER_HOME/$name" ] && db_compose "$name" down -v >/dev/null 2>&1
    rm -rf "${OPENMRS_DOCKER_HOME:?}/$name"
    common_teardown
}

db_compose() { # <instance> <compose args...>
    local dir="$OPENMRS_DOCKER_HOME/$1"; shift
    docker compose --env-file "$dir/env" -f "$dir/openmrs-db.yaml" "$@"
}

start_db() { # <instance>
    db_compose "$1" up -d openmrs-db >/dev/null 2>&1
    wait_for_mysql "$1-openmrs-db" root openmrs
}

set_env() { # <instance> <var> <value>
    sed -i "s/^$2=.*/$2=\"$3\"/" "$OPENMRS_DOCKER_HOME/$1/env"
}

binlog_files() { # <instance>
    docker exec "$1-openmrs-db" sh -c 'ls /var/lib/mysql | grep -c "^mysql-bin\." || true'
}

@test "binary logging is off by default" {
    local name
    name="$(instance)"
    SERVICES=openmrs-db create_instance "$name"
    start_db "$name"
    run mysql_exec "$name-openmrs-db" openmrs 'SELECT @@log_bin'
    assert_output 0
    run binlog_files "$name"
    assert_output 0
}

@test "when on, binlogs expire after OPENMRS_DB_BINLOG_EXPIRE_DAYS" {
    local name
    name="$(instance)"
    OPENMRS_DB_BINLOG_ENABLED=true OPENMRS_DB_BINLOG_EXPIRE_DAYS=3 SERVICES=openmrs-db create_instance "$name"
    start_db "$name"
    run mysql_exec "$name-openmrs-db" openmrs 'SELECT @@log_bin, @@expire_logs_days'
    assert_output $'1\t3'
}

@test "purge-binlogs has the server delete all but its current binlog, so it can then be turned off cleanly" {
    local name
    name="$(instance)"
    OPENMRS_DB_BINLOG_ENABLED=true SERVICES=openmrs-db create_instance "$name"
    start_db "$name"
    mysql_exec "$name-openmrs-db" openmrs 'CREATE TABLE openmrs.marker (id INT); INSERT INTO openmrs.marker VALUES (1); FLUSH LOGS; FLUSH LOGS'
    run mysql_exec "$name-openmrs-db" openmrs 'SHOW BINARY LOGS'
    assert [ "${#lines[@]}" -ge 3 ]

    MYSQL_PASSWORD=openmrs run "$UTILS/purge-binlogs.sh" --container="$name-openmrs-db"
    assert_success
    assert_output --regexp 'after: +1 file\(s\)'
    run binlog_files "$name"
    assert_output 2 # the current binlog and the index

    set_env "$name" OPENMRS_DB_BINLOG_ENABLED false
    start_db "$name"
    run mysql_exec "$name-openmrs-db" openmrs 'SELECT @@log_bin'
    assert_output 0
    run mysql_exec "$name-openmrs-db" openmrs 'SELECT id FROM openmrs.marker'
    assert_output 1
}

@test "purge-binlogs refuses when binary logging is off, since the server can't purge then" {
    local name
    name="$(instance)"
    SERVICES=openmrs-db create_instance "$name"
    start_db "$name"
    MYSQL_PASSWORD=openmrs run "$UTILS/purge-binlogs.sh" --container="$name-openmrs-db"
    assert_failure
    assert_output --partial 'binary logging is off'
}

@test "rejects an OPENMRS_DB_BINLOG_ENABLED value other than true or false" {
    local name
    name="$(instance)"
    OPENMRS_DB_BINLOG_ENABLED=yes SERVICES=openmrs-db create_instance "$name"
    db_compose "$name" up -d openmrs-db >/dev/null 2>&1
    sleep 3
    run docker logs "$name-openmrs-db"
    assert_output --partial "OPENMRS_DB_BINLOG_ENABLED must be true or false, got 'yes'"
}
