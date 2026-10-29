#!/usr/bin/env bats
# pihx start, stop, restart, status, pull, update, run-service and destroy, black-box through
# bin/pihx, against throwaway instances. modality-simulator and biometrics, given alpine as their
# image and an override that makes it sleep, are the light services; openmrs-db and petl are the
# ones with a setup and a job.

load ../helpers

setup_file() {
    export REGISTRY_CONTAINER
    REGISTRY_CONTAINER="$(file_res registry)"
    start_registry "$REGISTRY_CONTAINER"
    # A stand-in for an ETL image: a line per run, then PETL_EXIT_CODE.
    docker build -q -t distro-tools-test/stub-petl - >/dev/null <<'DOCKERFILE'
FROM alpine:3.21
CMD ["sh", "-c", "echo PETL-RAN; exit ${PETL_EXIT_CODE:-0}"]
DOCKERFILE
}
teardown_file() {
    docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
    common_teardown_file
}

setup() {
    cd "$BATS_TEST_TMPDIR"
    NAME="$(instance)"
    DIR="$PIHX_HOME/$NAME"
    unset OPENMRS_IMAGE_NAME
    export MODALITY_SIMULATOR_IMAGE_NAME=alpine MODALITY_SIMULATOR_IMAGE_TAG=3.21 \
        MODALITY_SIMULATOR_GATEWAY_AE=GW MODALITY_SIMULATOR_HOST_PORT=0 \
        MODALITY_SIMULATOR_IMAGE_DIR=/tmp \
        BIOMETRICS_IMAGE_NAME=alpine BIOMETRICS_IMAGE_TAG=3.21 BIOMETRICS_LICENSE_BASE64=eA== \
        PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1
}
teardown() {
    "$BIN/pihx" "$NAME" destroy --force >/dev/null 2>&1 || true
    remove_images "$NAME-"
    remove_images "$REGISTRY/$NAME-"
    common_teardown
}

# Makes the instance with <service>..., and keeps each that sleeps (alpine would exit at once).
create() { # <service>...
    local svc
    "$BIN/pihx" "$NAME" create --services="$(IFS=,; echo "$*")" >/dev/null
    for svc in "$@"; do
        case $svc in
            modality-simulator | biometrics)
                printf 'services:\n  %s:\n    init: true\n    command: ["sleep", "3600"]\n' "$svc" \
                    > "$DIR/$svc.override.yaml" ;;
        esac
    done
}

running() { docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$NAME" | sort; }

@test "start brings the stack up, status shows it, and stop removes the containers but keeps the volumes" {
    create modality-simulator
    run "$BIN/pihx" "$NAME" start
    assert_success
    assert_equal "$(running)" "$NAME-modality-simulator"
    run "$BIN/pihx" "$NAME" status
    assert_success
    assert_output --partial "$NAME-modality-simulator"
    refute_output --partial Busy
    run "$BIN/pihx" "$NAME" restart
    assert_success
    run "$BIN/pihx" "$NAME" stop
    assert_success
    assert_equal "$(running)" ""
    run docker volume inspect "${NAME}_modality-simulator-data"
    assert_success
}

@test "lifecycle commands refuse arguments they don't take" {
    create modality-simulator
    run "$BIN/pihx" "$NAME" start --build
    assert_failure
    assert_output --partial "unknown option '--build' for start"
    run "$BIN/pihx" "$NAME" logs -f
    assert_failure
    assert_output --partial "usage: pihx $NAME logs [service]"
    run "$BIN/pihx" "$NAME" run-service
    assert_failure
    assert_output --partial "usage: pihx $NAME run-service"
}

@test "env values with special characters reach the container unchanged" {
    # One through the service's env_file (its defaults and <svc>.env), one through `environment:`
    # interpolation; written by create, read back from the started container.
    local institution='A & B $HOME #x "q" `y` %z' ae='G$W #1 "q" `s`'
    MODALITY_SIMULATOR_INSTITUTION=$institution MODALITY_SIMULATOR_GATEWAY_AE=$ae \
        "$BIN/pihx" "$NAME" create --services=modality-simulator
    printf 'services:\n  modality-simulator:\n    init: true\n    command: ["sleep", "3600"]\n' \
        > "$DIR/modality-simulator.override.yaml"
    run "$BIN/pihx" "$NAME" start
    assert_success
    run docker exec "$NAME-modality-simulator" printenv MODALITY_SIMULATOR_INSTITUTION
    assert_success
    assert_output "$institution"
    run docker exec "$NAME-modality-simulator" printenv MODALITY_SIMULATOR_GATEWAY_AE
    assert_success
    assert_output "$ae"
}

@test "start fails, naming the setup, when the database account setup fails" {
    "$BIN/pihx" "$NAME" create --services=openmrs-db
    printf '%s\n' "OPENMRS_DB_ACCOUNT_BAD_USER='reports'" "OPENMRS_DB_ACCOUNT_BAD_PASSWORD=''" \
        "OPENMRS_DB_ACCOUNT_BAD_GRANTS='ALL ON *.*'" >> "$DIR/openmrs-db.env"
    run "$BIN/pihx" "$NAME" start
    assert_failure
    assert_output --partial "openmrs-db-accounts failed"
    assert_output --partial "OPENMRS_DB_ACCOUNT_BAD_PASSWORD"
    assert_line --index -1 --partial "error:"
}

@test "update pulls and brings the stack up, leaving containers that are unchanged" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    local id
    id=$(docker inspect -f '{{.Id}}' "$NAME-modality-simulator")
    run "$BIN/pihx" "$NAME" update
    assert_success
    assert_equal "$(docker inspect -f '{{.Id}}' "$NAME-modality-simulator")" "$id"
}

@test "removing a service file removes its containers on update, keeps volumes" {
    create modality-simulator biometrics
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running)" "$(printf '%s\n' "$NAME-biometrics" "$NAME-modality-simulator")"
    local keep
    keep=$(docker inspect -f '{{.Id}}' "$NAME-modality-simulator")
    rm "$DIR/biometrics.env" "$DIR/biometrics.override.yaml"
    run "$BIN/pihx" "$NAME" update
    assert_success
    assert_equal "$(running)" "$NAME-modality-simulator"
    assert_equal "$(docker inspect -f '{{.Id}}' "$NAME-modality-simulator")" "$keep"
    run docker volume inspect "${NAME}_biometrics-data" "${NAME}_biometrics-licensing"
    assert_success
}

@test "remove-service on a running instance removes only that service's containers, and keeps its volumes" {
    create modality-simulator biometrics
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    local keep
    keep=$(docker inspect -f '{{.Id}}' "$NAME-modality-simulator")
    run "$BIN/pihx" "$NAME" remove-service biometrics
    assert_success
    assert_equal "$(running)" "$NAME-modality-simulator"
    assert_equal "$(docker inspect -f '{{.Id}}' "$NAME-modality-simulator")" "$keep"
    run docker volume inspect "${NAME}_biometrics-data"
    assert_success
    assert [ ! -e "$DIR/biometrics.env" ]
}

@test "run-service runs a profiled container once with the given command, and start leaves it alone" {
    create modality-simulator
    cat >> "$DIR/modality-simulator.override.yaml" <<'YAML'
  job:
    image: alpine:3.21
    profiles: ["job"]
YAML
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running)" "$NAME-modality-simulator"
    run "$BIN/pihx" "$NAME" run-service job echo "hello from job"
    assert_success
    assert_output --partial 'hello from job'
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.service=job" --filter "label=com.docker.compose.project=$NAME")" ""
    run "$BIN/pihx" "$NAME" run-service job sh -c 'exit 7'
    assert_failure 7
    run "$BIN/pihx" "$NAME" run-service nope
    assert_failure
    assert_output --partial "nope not present on $NAME"
}

@test "run-service --pull pulls the named service's image first" {
    create modality-simulator
    run "$BIN/pihx" "$NAME" run-service --pull modality-simulator echo PULLED
    assert_success
    assert_output --partial PULLED
}

# --- jobs: petl --------------------------------------------------------------------------------

@test "a job on a stopped instance fails at its setups, and the job doesn't run" {
    create openmrs-db petl
    run "$BIN/pihx" "$NAME" run-service petl echo PETL-RAN
    assert_failure
    assert_output --partial 'openmrs-db-accounts failed'
    refute_output --partial 'PETL-RAN'
    assert_equal "$(running)" ""
}

@test "a job runs the setups but doesn't recreate openmrs-db after an env change, and holds the lock while it runs" {
    create openmrs-db petl
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    local before
    before=$(docker inspect -f '{{.Id}}' "$NAME-openmrs-db")
    echo "OPENMRS_DB_OPT_max_allowed_packet='512M'" >> "$DIR/openmrs-db.env"
    run "$BIN/pihx" "$NAME" run-service petl echo PETL-RAN
    assert_success
    assert_output --partial 'PETL-RAN'
    assert_equal "$(docker inspect -f '{{.Id}}' "$NAME-openmrs-db")" "$before"

    "$BIN/pihx" "$NAME" run-service petl sleep 8 > petl.log 2>&1 3>&- &
    local petl=$!
    until grep -q 'run-service' "$DIR/.lock" 2>/dev/null && docker ps --format '{{.Names}}' | grep -q "^$NAME-petl"; do
        kill -0 "$petl" 2>/dev/null || { cat petl.log; fail "run-service ended early"; }
        sleep 0.2
    done
    run "$BIN/pihx" "$NAME" start
    assert_failure
    assert_output --partial "$NAME is busy: pihx $NAME run-service (pid"
    run "$BIN/pihx" "$NAME" update
    assert_failure
    assert_output --partial "$NAME is busy: pihx $NAME run-service (pid"
    run "$BIN/pihx" "$NAME" status
    assert_success
    assert_output --partial "Busy: pihx $NAME run-service"
    run env PIHX_LOCK_WAIT=60 "$BIN/pihx" "$NAME" start
    assert_success
    wait "$petl"
}

petl_container() { docker ps -aq --filter "name=^$NAME-petl$"; }

@test "a job's own runs reuse one kept container and exit with its exit code; stop removes it, destroy removes its volume" {
    PETL_IMAGE_NAME=distro-tools-test/stub-petl PETL_IMAGE_TAG=latest \
        "$BIN/pihx" "$NAME" create --services=openmrs-db,petl
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    run "$BIN/pihx" "$NAME" run-service petl
    assert_success
    assert_output --partial 'PETL-RAN'
    local first
    first=$(petl_container)
    [ -n "$first" ] || fail "no kept petl container"
    run "$BIN/pihx" "$NAME" run-service petl
    assert_success
    assert_equal "$(petl_container)" "$first"
    run docker logs "$NAME-petl"
    assert_equal "$(grep -c PETL-RAN <<< "$output")" 2
    # A config change recreates it; the run's exit code is PETL's.
    echo "PETL_EXIT_CODE='3'" >> "$DIR/petl.env"
    run "$BIN/pihx" "$NAME" run-service petl
    assert_failure 3
    [ "$(petl_container)" != "$first" ] || fail "an env change didn't recreate the kept container"
    assert_equal "$(docker inspect -f '{{.State.ExitCode}}' "$NAME-petl")" 3

    run "$BIN/pihx" "$NAME" stop
    assert_success
    assert_equal "$(petl_container)" ""
    run docker volume ls -q --filter "name=^${NAME}_petl-data$"
    assert_output "${NAME}_petl-data"
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    run "$BIN/pihx" "$NAME" run-service petl
    assert_failure 3
    run "$BIN/pihx" "$NAME" destroy --force
    assert_success
    run docker volume ls -q --filter "name=^${NAME}_petl-data$"
    assert_output ''
    assert_equal "$(petl_container)" ""
}

# --- replaced images ---------------------------------------------------------------------------

# Points the instance's simulator at <ref> and starts it.
start_on() { # <ref>
    local name=${1%:*} tag=${1##*:}
    sed -i '/^MODALITY_SIMULATOR_IMAGE_\(NAME\|TAG\)=/d' "$DIR/modality-simulator.env"
    printf "MODALITY_SIMULATOR_IMAGE_NAME='%s'\nMODALITY_SIMULATOR_IMAGE_TAG='%s'\n" "$name" "$tag" \
        >> "$DIR/modality-simulator.env"
    run "$BIN/pihx" "$NAME" start
    assert_success
}

@test "a new tag: the image it replaced is removed, if a registry has it" {
    create modality-simulator
    local old="$REGISTRY/$NAME-app:1" new="$REGISTRY/$NAME-app:2" old_id
    build_test_image "$old" "$NAME-one" && docker push -q "$old" >/dev/null
    build_test_image "$new" "$NAME-two" && docker push -q "$new" >/dev/null
    start_on "$old"
    old_id=$(image_id "$old")
    start_on "$new"
    assert_output --partial "Removed the replaced image ${old_id#sha256:}"
    [ -z "$(image_id "$old")" ] || fail "$old is still there"
    [ -n "$(image_id "$new")" ] || fail "$new, in use, was removed"
}

@test "a new image under the same tag: the one it replaced, untagged, is removed" {
    create modality-simulator
    local ref="$NAME-same:latest" old_id
    build_test_image "$ref" "$NAME-one"
    start_on "$ref"
    old_id=$(image_id "$ref")
    build_test_image "$ref" "$NAME-two"
    start_on "$ref"
    run docker image inspect "$old_id"
    assert_failure
}

@test "a local build still tagged, which no registry has, is kept" {
    create modality-simulator
    local local_ref="$NAME-local:1" new="$REGISTRY/$NAME-app:2"
    build_test_image "$local_ref" "$NAME-local"
    build_test_image "$new" "$NAME-two" && docker push -q "$new" >/dev/null
    start_on "$local_ref"
    start_on "$new"
    [ -n "$(image_id "$local_ref")" ] || fail "$local_ref, a local build, was removed"
}

@test "an image another container is made from is kept" {
    create modality-simulator
    local old="$REGISTRY/$NAME-app:1" new="$REGISTRY/$NAME-app:2"
    build_test_image "$old" "$NAME-one" && docker push -q "$old" >/dev/null
    build_test_image "$new" "$NAME-two" && docker push -q "$new" >/dev/null
    docker run -d --name "$NAME-other" "$old" >/dev/null
    start_on "$old"
    start_on "$new"
    [ -n "$(image_id "$old")" ] || fail "$old, in use by $NAME-other, was removed"
}

# --- destroy -----------------------------------------------------------------------------------

@test "destroy removes the instance's containers, volumes and directory, and nothing else" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    local other="$NAME-b"
    "$BIN/pihx" "$other" create --services=modality-simulator >/dev/null
    printf 'services:\n  modality-simulator:\n    init: true\n    command: ["sleep", "3600"]\n' \
        > "$PIHX_HOME/$other/modality-simulator.override.yaml"
    "$BIN/pihx" "$other" start >/dev/null 2>&1
    run "$BIN/pihx" "$NAME" destroy --force
    assert_success
    assert_output --partial "Removed instance directory $DIR"
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    assert_equal "$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME")" ""
    assert [ ! -e "$DIR" ]
    assert_equal "$(docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$other")" "$other-modality-simulator"
    assert [ -d "$PIHX_HOME/$other" ]
    run docker volume inspect "${other}_modality-simulator-data"
    assert_success
    "$BIN/pihx" "$other" destroy --force >/dev/null
}

@test "destroy asks first: anything but y leaves the instance alone" {
    create modality-simulator
    run bash -c "echo n | '$BIN/pihx' '$NAME' destroy"
    assert_success
    assert_output --partial "This will stop the stack, delete all volumes, and remove $DIR."
    assert [ -d "$DIR" ]
    run bash -c "'$BIN/pihx' '$NAME' destroy < /dev/null"
    assert_success
    assert [ -d "$DIR" ]
    run bash -c "echo y | '$BIN/pihx' '$NAME' destroy"
    assert_success
    assert [ ! -e "$DIR" ]
}

@test "destroy removes a profiled service's kept container and volume too" {
    create openmrs-db petl
    run "$BIN/pihx" "$NAME" destroy --force
    assert_success
    assert [ ! -e "$DIR" ]
}

@test "destroy removes everything even when Compose can't read the instance" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running)" "$NAME-modality-simulator"
    echo 'services: [' > "$DIR/modality-simulator.override.yaml"   # Compose can't read it
    run "$BIN/pihx" "$NAME" destroy --force
    assert_success
    # (Recent Compose's `down` finds the containers by their project label itself, and then pihx's
    # own fallback by label isn't reached; either way everything goes.)
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    assert_equal "$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME")" ""
    assert [ ! -e "$DIR" ]
}

@test "destroy removes root-owned files a container left in the instance directory" {
    create modality-simulator
    docker run --rm -v "$DIR:/d" alpine:3.21 sh -c 'mkdir /d/out && touch /d/out/report && chmod 700 /d/out'
    run "$BIN/pihx" "$NAME" destroy --force
    assert_success
    assert [ ! -e "$DIR" ]
}
