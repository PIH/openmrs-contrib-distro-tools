#!/usr/bin/env bats
# services/openmrs/start/create-tables, with a fake docker: OPENMRS_DB_FOUND_EMPTY is true only when
# the database answers that its schema exists and has no tables. Anything else gives false, with a
# line saying why, and the script only ever starts openmrs-db and reads information_schema.

load ../helpers

SCRIPT="$REPO_ROOT/services/openmrs/start/create-tables"

setup() {
    cd "$BATS_TEST_TMPDIR"
    mkdir bin
    # FAKE_PS / FAKE_INSPECT / FAKE_UP / FAKE_EXEC: exit statuses; FAKE_IDS: the openmrs container's
    # id (none by default); FAKE_ENV: its environment; FAKE_COUNTS: what the query prints.
    cat > bin/docker <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/docker-calls"
case " $* " in
    *" ps "*) [ "${FAKE_PS:-0}" -eq 0 ] || exit "$FAKE_PS"; printf '%b' "${FAKE_IDS-}" ;;
    " inspect "*) [ "${FAKE_INSPECT:-0}" -eq 0 ] || exit "$FAKE_INSPECT"; printf '%b' "${FAKE_ENV-}" ;;
    *" up "*) exit "${FAKE_UP:-0}" ;;
    *" exec "*) [ "${FAKE_EXEC:-0}" -eq 0 ] || exit "$FAKE_EXEC"; printf '%b' "${FAKE_COUNTS-}" ;;
    *) exit 99 ;;
esac
FAKE
    chmod +x bin/docker
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH" PIHX_INSTANCE_DIR="$BATS_TEST_TMPDIR"
    unset OPENMRS_CREATE_TABLES
}

@test "an empty schema gives true" {
    FAKE_COUNTS='1\n0\n' run --separate-stderr "$SCRIPT"
    assert_success
    assert_output 'OPENMRS_DB_FOUND_EMPTY=true'
    [[ "$stderr" == *"the database has no tables: OpenMRS will create them"* ]]
}

@test "a schema with tables gives false" {
    FAKE_COUNTS='1\n187\n' run --separate-stderr "$SCRIPT"
    assert_success
    assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
    [[ "$stderr" == *"the database has tables"* ]]
}

@test "a failed check gives false, saying why" {
    FAKE_UP=1 run --separate-stderr "$SCRIPT"
    assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
    [[ "$stderr" == *"openmrs-db didn't become healthy"* ]]
    run grep -c ' exec ' docker-calls
    assert_output 0

    FAKE_EXEC=1 FAKE_COUNTS='1\n0\n' run --separate-stderr "$SCRIPT"
    assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
    [[ "$stderr" == *"couldn't count the database's tables"* ]]
}

@test "unexpected output gives false" {
    local counts
    for counts in '' '0\n0\n' '1\t0\n' '1\n-1\n' '1\n' '1\n0\n0\n' 'ERROR 1045\n' '1\n0x\n' '1 0\n'; do
        FAKE_COUNTS=$counts run --separate-stderr "$SCRIPT"
        assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
        [[ "$stderr" == *"OpenMRS won't create"* ]] || fail "$counts: $stderr"
    done
}

@test "OPENMRS_CREATE_TABLES decides without touching the database" {
    OPENMRS_CREATE_TABLES=true FAKE_COUNTS='1\n0\n' run --separate-stderr "$SCRIPT"
    assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
    [[ "$stderr" == *"OPENMRS_CREATE_TABLES=true (openmrs.env) decides"* ]]
    [ ! -e docker-calls ]
}

@test "it only starts openmrs-db and reads information_schema" {
    FAKE_COUNTS='1\n0\n' run "$SCRIPT"
    run grep -E '^(compose|inspect) ' docker-calls
    assert_line --index 0 "compose --project-directory $BATS_TEST_TMPDIR ps -a -q openmrs"
    assert_line --index 1 "compose --project-directory $BATS_TEST_TMPDIR up -d --wait --wait-timeout 600 openmrs-db"
    assert_line --index 2 --regexp "^compose --project-directory $BATS_TEST_TMPDIR exec -T openmrs-db sh -c "
    [ "${#lines[@]}" -eq 3 ]
    run grep -Eiw 'drop|truncate|delete|insert|update|alter|create|down|volume|rm' docker-calls
    assert_failure
    [ "$(grep -o 'SELECT COUNT(\*) FROM information_schema' docker-calls | wc -l)" -eq 2 ]
}

NEVER=0001-01-01T00:00:00Z

# FAKE_ENV for an openmrs container: <first line: state health finished-at check-exit-codes> <value>
container() { printf '%s\n%s\n' "$1" "${2:+OMRS_CONFIG_CREATE_TABLES=$2}"; }

checked_database() { grep -qE ' (up|exec) ' docker-calls; }

@test "an existing container's false is kept, whatever its state, without checking the database" {
    local state
    for state in "running healthy 2026-10-29T10:00:00Z 0," "exited unhealthy 2026-10-29T10:00:00Z 1," \
            "running starting $NEVER "; do
        rm -f docker-calls
        FAKE_IDS='abc\n' FAKE_ENV="$(container "$state" false)" FAKE_COUNTS='1\n0\n' \
            run --separate-stderr "$SCRIPT"
        assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
        [[ "$stderr" == *"the openmrs container exists: keeping its create_tables (false)"* ]]
        ! checked_database || fail "$state: checked the database"
    done
}

@test "an existing container's true is kept only while its first install can't have finished" {
    local state
    for state in "running starting $NEVER " "running starting $NEVER 1,1,10," "running starting $NEVER 137,"; do
        rm -f docker-calls
        FAKE_IDS='abc\n' FAKE_ENV="$(container "$state" true)" FAKE_COUNTS='1\n5\n' \
            run --separate-stderr "$SCRIPT"
        assert_output 'OPENMRS_DB_FOUND_EMPTY=true'
        [[ "$stderr" == *"still on its first start: keeping its create_tables (true)"* ]]
        ! checked_database || fail "$state: checked the database"
    done
}

@test "an existing container's true that may have finished installing is decided from the database" {
    local state
    # healthy, unhealthy, exited, created but never started, restarted or stopped once (FinishedAt
    # set), a check that passed, or no health at all
    for state in "running healthy $NEVER 0," "running unhealthy $NEVER 1,1,1," \
            "exited unhealthy 2026-10-29T10:00:00Z 1," "created none $NEVER " \
            "running starting 2026-10-29T10:00:00Z " "running starting $NEVER 1,0,1," \
            "running starting $NEVER 0," "running none $NEVER " "paused starting $NEVER "; do
        rm -f docker-calls
        FAKE_IDS='abc\n' FAKE_ENV="$(container "$state" true)" FAKE_COUNTS='1\n5\n' \
            run --separate-stderr "$SCRIPT"
        assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
        [[ "$stderr" == *"can't keep its create_tables; checking the database"* ]] || fail "$state: $stderr"
        [[ "$stderr" == *"the database has tables"* ]] || fail "$state: $stderr"
        checked_database || fail "$state: didn't check the database"
    done
    # An empty database still gives true then.
    FAKE_IDS='abc\n' FAKE_ENV="$(container "running healthy $NEVER 0," true)" FAKE_COUNTS='1\n0\n' \
        run --separate-stderr "$SCRIPT"
    assert_output 'OPENMRS_DB_FOUND_EMPTY=true'
}

@test "a container that can't be read, or a failed lookup, is decided from the database, with a warning" {
    FAKE_PS=1 FAKE_COUNTS='1\n5\n' run --separate-stderr "$SCRIPT"
    assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
    [[ "$stderr" == *"warning: couldn't tell whether the openmrs container exists; checking the database"* ]]
    checked_database
    rm -f docker-calls
    FAKE_IDS='abc\n' FAKE_INSPECT=1 FAKE_COUNTS='1\n5\n' run --separate-stderr "$SCRIPT"
    assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
    [[ "$stderr" == *"warning: couldn't read the openmrs container's settings; checking the database"* ]]
    checked_database
    local value
    for value in '' yes 'true\nOMRS_CONFIG_CREATE_TABLES=true'; do
        rm -f docker-calls
        FAKE_IDS='abc\n' FAKE_ENV="$(container "running starting $NEVER " "$value")" FAKE_COUNTS='1\n5\n' \
            run --separate-stderr "$SCRIPT"
        assert_output 'OPENMRS_DB_FOUND_EMPTY=false'
        [[ "$stderr" == *"can't keep its create_tables; checking the database"* ]] || fail "$value: $stderr"
        checked_database || fail "$value: didn't check the database"
    done
}
