#!/usr/bin/env bats
# pihx wait, summary and a service's own commands, black-box through bin/pihx, against throwaway
# instances. For wait, openmrs-db is alpine (overridden to be healthy at once) and openmrs the stub
# image, whose healthcheck (a curl shim, overridden to a short interval) decides.

load ../helpers

setup_file() {
    build_stub_openmrs_image
}
teardown_file() {
    common_teardown_file
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    DIR="$PIHX_HOME/$NAME"
    mkdir run
}
teardown() {
    remove_test_instance "$NAME"
    common_teardown
}

# An instance with alpine as the database (healthy at once, its accounts setup a no-op) and the
# stub OpenMRS, whose healthcheck now runs every second and counts failures from the start.
create_light() { # <openmrs entrypoint override, as a YAML list, or empty for the stub's own>
    OPENMRS_DB_IMAGE_NAME=alpine OPENMRS_DB_IMAGE_TAG=3.21 \
        OPENMRS_IMAGE_NAME="$STUB_OPENMRS_IMAGE" OPENMRS_IMAGE_TAG=latest \
        "$BIN/pihx" "$NAME" create --services=openmrs-db,openmrs >/dev/null
    cat > "$DIR/openmrs-db.override.yaml" <<'YAML'
services:
  openmrs-db:
    entrypoint: ["sleep", "3600"]
    healthcheck: {test: ["CMD", "true"], interval: 1s, start_period: 0s}
  openmrs-db-accounts:
    entrypoint: ["true"]
YAML
    cat > "$DIR/openmrs.override.yaml" <<YAML
services:
  openmrs:
    ${1:+entrypoint: $1}
    healthcheck: {interval: 1s, timeout: 1s, retries: 1, start_period: 0s}
YAML
}

@test "wait fails fast when openmrs turns unhealthy" {
    # sleeps without touching /tmp/started, so the shim curl keeps failing
    create_light '["sleep", "3600"]'
    run "$BIN/pihx" "$NAME" start
    assert_success
    SECONDS=0
    PIHX_WAIT_TIMEOUT=120 run "$BIN/pihx" "$NAME" wait
    assert_failure
    assert_output --partial "$NAME-openmrs reported unhealthy"
    assert_output --partial "$NAME-openmrs did not become ready"
    assert [ "$SECONDS" -lt 60 ]
}

@test "wait succeeds once every container with a healthcheck is healthy" {
    create_light
    "$BIN/pihx" "$NAME" start >/dev/null
    PIHX_WAIT_TIMEOUT=120 run "$BIN/pihx" "$NAME" wait
    assert_success
    assert_output --partial "$NAME-openmrs is healthy"
    assert_output --partial "$NAME is ready."
}

@test "wait refuses a stopped instance, arguments and a bad timeout" {
    create_light
    run "$BIN/pihx" "$NAME" wait
    assert_failure
    assert_output --partial "$NAME has no running containers"
    run "$BIN/pihx" "$NAME" wait now
    assert_failure
    assert_output --partial "unknown option 'now' for wait"
    PIHX_WAIT_TIMEOUT=soon run "$BIN/pihx" "$NAME" wait
    assert_failure
    assert_output --partial "PIHX_WAIT_TIMEOUT must be a positive number of seconds, not 'soon'"
}

@test "summary matches fingerprint's output, running or stopped, a data directory section after the database's" {
    OPENMRS_IMAGE_NAME="$STUB_OPENMRS_IMAGE" OPENMRS_IMAGE_TAG=latest \
        "$BIN/pihx" "$NAME" create --services=openmrs-db,openmrs >/dev/null
    run "$BIN/pihx" "$NAME" summary
    assert_failure
    assert_output --partial "${NAME}_db-data doesn't exist -- nothing to summarize"
    assert_output --partial "openmrs-db: summary.sh failed"
    write_tiny_dump run/openmrs-db.sql
    make_data_fixture run/openmrs
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from "$BATS_TEST_TMPDIR/run"
    assert_success
    # stopped, right after initialize: read from the volume with the instance's image and options
    run "$BIN/pihx" "$NAME" summary --output=stopped.txt
    assert_success
    assert_output --partial "Wrote stopped.txt."
    # the file is the caller's, even outside the mounted paths, and no temporary file is left
    assert_equal "$(stat -c %U stopped.txt)" "$(id -un)"
    assert_equal "$(ls | grep -c 'stopped.txt.')" 0
    run cat stopped.txt
    # the instance's OPENMRS_DB_OPT_character_set_server, not the image's default (latin1 on 5.6)
    assert_line 'character_set_server utf8'
    assert_line 'openmrs.marker 1'
    assert_line 'complex_obs/ files=1 bytes=4'
    refute_output --partial 'modules/'
    assert_equal "$(grep '^\[' stopped.txt | paste -sd' ' -)" \
        "[server] [databases] [rows] [objects] [recent] [accounts] [data-dir]"
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    wait_for_mysql "$NAME-openmrs-db" root openmrs
    run "$BIN/pihx" "$NAME" summary --output running.txt
    assert_success
    MYSQL_PASSWORD=openmrs "$UTILS/fingerprint.sh" --container="$NAME-openmrs-db" \
        --data-dir="${NAME}_openmrs-data" --exclude-distribution-artifacts --output=fingerprint.txt 2>/dev/null
    run diff fingerprint.txt running.txt
    assert_success
    run diff stopped.txt running.txt
    assert_success
    # what the image supplies is included on request; without --output it prints
    run "$BIN/pihx" "$NAME" summary --include-distribution-artifacts
    assert_success
    assert_line 'modules/ files=1 bytes=5'
    run "$BIN/pihx" "$NAME" summary --bogus
    assert_failure
    assert_output --partial "unknown option '--bogus' for summary"
}

@test "summary --output fails with an error line when the file can't be written, and leaves nothing" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db >/dev/null
    run "$BIN/pihx" "$NAME" summary --output=/nosuchdir/summary.txt
    assert_failure
    assert_output --partial "error: can't write /nosuchdir/summary.txt"
    # a failing summary leaves no file either
    run "$BIN/pihx" "$NAME" summary --output=out.txt
    assert_failure
    assert_output --partial "nothing to summarize"
    assert_equal "$(ls)" run
    mkdir adir
    run "$BIN/pihx" "$NAME" summary --output=adir
    assert_failure
    assert_output --partial "error: adir is a directory"
    assert_equal "$(ls adir)" ""
}

in_volume() { # <volume> <sh command>
    docker run --rm -v "$1:/data" alpine:3.21 sh -c "$2"
}

@test "a service command runs against the instance: openmrs-db reset-accounts sets the passwords now in the env files" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db >/dev/null
    write_tiny_dump run/openmrs-db.sql
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from "$BATS_TEST_TMPDIR/run"
    assert_success
    # openmrs-data as OpenMRS leaves it after its first start
    docker volume create "${NAME}_openmrs-data" >/dev/null
    in_volume "${NAME}_openmrs-data" '
        printf "connection.url=jdbc\\\\:mysql\\\\://openmrs-db\\\\:3306/openmrs\nconnection.username=openmrs\nconnection.password=openmrs\nmail.smtp.host=smtp.example.org\n" > /data/openmrs-runtime.properties
        chown 1001:0 /data/openmrs-runtime.properties && chmod 640 /data/openmrs-runtime.properties'
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1

    printf '%s\n' "OPENMRS_DB_PASSWORD='n3w\\pw'" "OPENMRS_DB_ROOT_PASSWORD='n3w-root'" >> "$DIR/openmrs-db.env"
    run "$BIN/pihx" "$NAME" openmrs-db reset-accounts
    assert_success
    assert_output --partial "Set the password of root@localhost"
    assert_output --partial "Set connection.username and connection.password"
    # no secret is echoed
    refute_output --partial 'n3w'

    wait_for_mysql "$NAME-openmrs-db" root n3w-root
    run mysql_exec "$NAME-openmrs-db" openmrs 'SELECT 1'
    assert_failure
    run docker exec "$NAME-openmrs-db" sh -c 'mysql -h127.0.0.1 -uopenmrs "-pn3w\\pw" -N -e "SELECT id FROM openmrs.marker" 2>/dev/null'
    assert_output 1
    # the properties format doubles a backslash; everything else, and the file's owner and mode, stay
    run in_volume "${NAME}_openmrs-data" 'grep -c "^connection.password=" /data/openmrs-runtime.properties; cat /data/openmrs-runtime.properties; stat -c "%u:%g %a" /data/openmrs-runtime.properties; grep -c "^connection.password=openmrs$" /data/openmrs-runtime.properties.bak'
    assert_line --index 0 1
    assert_line 'connection.password=n3w\\pw'
    assert_line 'connection.url=jdbc\:mysql\://openmrs-db\:3306/openmrs'
    assert_line 'mail.smtp.host=smtp.example.org'
    assert_line '1001:0 640'
    assert_line --index -1 1
}

@test "reset-accounts works with no openmrs-data volume, and refuses with no database volume" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db >/dev/null
    run "$BIN/pihx" "$NAME" openmrs-db reset-accounts
    assert_failure
    assert_output --partial "${NAME}_db-data doesn't exist -- nothing to reset"
    write_tiny_dump run/openmrs-db.sql
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from "$BATS_TEST_TMPDIR/run"
    assert_success
    printf '%s\n' "OPENMRS_DB_PASSWORD='rotated-pw'" >> "$DIR/openmrs-db.env"
    run "$BIN/pihx" "$NAME" openmrs-db reset-accounts
    assert_success
    assert_output --partial "Set the password of openmrs@%"
    refute_output --partial "openmrs-runtime.properties"
    wait_for_mysql "$NAME-openmrs-db" openmrs rotated-pw
}

@test "reset-accounts starts the instance with its setup checked, and a failing setup fails it" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db >/dev/null
    write_tiny_dump run/openmrs-db.sql
    run timeout 300 "$BIN/pihx" "$NAME" initialize --from "$BATS_TEST_TMPDIR/run"
    assert_success
    printf '%s\n' "OPENMRS_DB_ACCOUNT_BAD_USER='reports'" "OPENMRS_DB_ACCOUNT_BAD_PASSWORD=''" \
        "OPENMRS_DB_ACCOUNT_BAD_GRANTS='ALL ON *.*'" >> "$DIR/openmrs-db.env"
    run "$BIN/pihx" "$NAME" openmrs-db reset-accounts
    assert_failure
    assert_output --partial "openmrs-db-accounts failed"
}

@test "_start is refused from a shell, even with PIHX_LOCK_HELD set" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db >/dev/null
    run "$BIN/pihx" "$NAME" _start
    assert_failure 2
    PIHX_LOCK_HELD="$NAME" run "$BIN/pihx" "$NAME" _start
    assert_failure 2
    assert_output --partial "error: _start is for service commands that hold the lock"
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
}

@test "a service command holds the instance lock" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db >/dev/null
    ( exec 9>>"$DIR/.lock"; flock 9; echo "initialize (pid $BASHPID, started now)" > "$DIR/.lock"; exec sleep 30 ) 3>&- &
    local holder=$!
    until grep -q initialize "$DIR/.lock" 2>/dev/null; do sleep 0.1; done
    run "$BIN/pihx" "$NAME" openmrs-db reset-accounts
    kill "$holder" 2>/dev/null || true
    assert_failure
    assert_output --partial "$NAME is busy: initialize (pid"
}

@test "a service's commands are listed, and an unknown one is refused" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db,openmrs >/dev/null
    run "$BIN/pihx" "$NAME" openmrs-db
    assert_success
    assert_output --partial "Commands of openmrs-db:"
    assert_output --partial "reset-accounts"
    run "$BIN/pihx" "$NAME" openmrs
    assert_success
    assert_output "openmrs has no commands."
    run "$BIN/pihx" "$NAME" openmrs-db reset
    assert_failure
    assert_output --partial "openmrs-db has no command 'reset'"
}

@test "commands of a service the instance doesn't have are refused" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db >/dev/null
    run "$BIN/pihx" "$NAME" openmrs reset-accounts
    assert_failure
    assert_output --partial "$NAME doesn't have the service 'openmrs'"
    assert_output --partial "add-service openmrs"
    run "$BIN/pihx" "$NAME" nosuch thing
    assert_failure
    assert_output --partial "unknown command 'nosuch'"
}
