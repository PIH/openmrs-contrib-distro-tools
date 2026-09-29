#!/usr/bin/env bats
# openmrs-db's server options come from OPENMRS_DB_OPT_* variables in the env file; binary logging
# is one such option, and purge-binlogs lets the server clean up before it's turned off.

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

binlog_files() { # <instance>
    docker exec "$1-openmrs-db" sh -c 'ls /var/lib/mysql | grep -c "^mysql-bin\." || true'
}

@test "the default options apply, and binary logging is left at the server's default (off on 5.6)" {
    local name
    name="$(instance)"
    SERVICES=openmrs-db create_instance "$name"
    start_db "$name"
    run mysql_exec "$name-openmrs-db" openmrs 'SELECT @@character_set_server, @@max_allowed_packet, @@net_read_timeout, @@log_bin_trust_function_creators, @@log_bin'
    assert_output $'utf8\t1073741824\t3600\t1\t0'
}

@test "an OPENMRS_DB_OPT_* option with no default is passed, and an empty one as a bare flag" {
    local name
    name="$(instance)"
    OPENMRS_DB_OPT_long_query_time=7 OPENMRS_DB_OPT_skip_name_resolve= SERVICES=openmrs-db create_instance "$name"
    start_db "$name"
    run mysql_exec "$name-openmrs-db" openmrs 'SELECT @@long_query_time, @@skip_name_resolve'
    assert_output $'7.000000\t1'
}

@test "binlog turned on through options; purge-binlogs leaves only the current one, so it can then be turned off" {
    local name env
    name="$(instance)"
    OPENMRS_DB_OPT_log_bin=mysql-bin OPENMRS_DB_OPT_server_id=5 OPENMRS_DB_OPT_expire_logs_days=3 \
        SERVICES=openmrs-db create_instance "$name"
    start_db "$name"
    run mysql_exec "$name-openmrs-db" openmrs 'SELECT @@log_bin, @@server_id, @@expire_logs_days'
    assert_output $'1\t5\t3'
    mysql_exec "$name-openmrs-db" openmrs 'CREATE TABLE openmrs.marker (id INT); INSERT INTO openmrs.marker VALUES (1); FLUSH LOGS; FLUSH LOGS'

    MYSQL_PASSWORD=openmrs run "$UTILS/purge-binlogs.sh" --container="$name-openmrs-db"
    assert_success
    assert_output --regexp 'after: +1 file\(s\)'
    run binlog_files "$name"
    assert_output 2 # the current binlog and the index

    env="$OPENMRS_DOCKER_HOME/$name/env"
    sed -i '/^OPENMRS_DB_OPT_log_bin=/d; /^OPENMRS_DB_OPT_expire_logs_days=/d' "$env"
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
