#!/usr/bin/env bats
# pihx start, stop, restart, status, pull, update, run-service, external volumes, archive and
# destroy, black-box through bin/pihx, against throwaway instances. modality-simulator and
# biometrics, given alpine as their image and an override that makes it sleep, are the light
# services; openmrs-db and petl are the ones with a setup and a job.

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
        MODALITY_SIMULATOR_HOST_PORT=0 \
        MODALITY_SIMULATOR_IMAGE_DIR=/tmp \
        BIOMETRICS_IMAGE_NAME=alpine BIOMETRICS_IMAGE_TAG=3.21 BIOMETRICS_LICENSE_BASE64=eA== \
        PETL_IMAGE_NAME=alpine PETL_IMAGE_TAG=3.21 PETL_MYSQL_PASSWORD=Pw-1
}
teardown() {
    remove_test_instance "$NAME"
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
    local speed='A & B $HOME #x "q" `y` %z' license='G$W #1 "q" `s`'
    BIOMETRICS_MATCHING_SPEED=$speed BIOMETRICS_LICENSE_BASE64=$license \
        "$BIN/pihx" "$NAME" create --services=biometrics
    printf 'services:\n  biometrics:\n    init: true\n    command: ["sleep", "3600"]\n' \
        > "$DIR/biometrics.override.yaml"
    run "$BIN/pihx" "$NAME" start
    assert_success
    run docker exec "$NAME-biometrics" printenv BIOMETRICS_MATCHING_SPEED
    assert_success
    assert_output "$speed"
    run docker exec "$NAME-biometrics" printenv PIH_BIOMETRICS_LICENSE_BASE64
    assert_success
    assert_output "$license"
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
    printf '  job:\n    image: alpine:3.21\n    profiles: ["job"]\n' >> "$DIR/modality-simulator.override.yaml"
    run "$BIN/pihx" "$NAME" run-service --pull job echo PULLED
    assert_success
    assert_output --partial PULLED
}

@test "run-service refuses a service that runs with the instance, and starts nothing" {
    create modality-simulator
    run "$BIN/pihx" "$NAME" run-service modality-simulator echo RAN
    assert_failure 2
    assert_output --partial "modality-simulator runs with the instance"
    refute_output --partial RAN
    assert_equal "$(running)" ""
}

@test "run-service doesn't start what the service depends on" {
    create modality-simulator
    printf '  job:\n    image: alpine:3.21\n    profiles: ["job"]\n    depends_on: [modality-simulator]\n' \
        >> "$DIR/modality-simulator.override.yaml"
    run "$BIN/pihx" "$NAME" run-service job echo JOB-RAN
    assert_success
    assert_output --partial JOB-RAN
    assert_equal "$(running)" ""
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
    run_destroy "$BIN/pihx" "$NAME"
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

# --- external volumes --------------------------------------------------------------------------

@test "start creates the instance's volumes, labelled; compose down -v leaves them" {
    create modality-simulator biometrics
    run docker volume ls -q --filter "name=^${NAME}_"
    assert_output ''
    run "$BIN/pihx" "$NAME" start
    assert_success
    assert_output --partial "Created volume ${NAME}_modality-simulator-data"
    run bash -c "docker volume ls -q --filter label=pihx.instance=$NAME | sort"
    assert_output "$(printf '%s\n' "${NAME}_biometrics-data" "${NAME}_biometrics-licensing" \
        "${NAME}_modality-simulator-data" | sort)"
    docker run --rm -v "${NAME}_modality-simulator-data:/v" alpine:3.21 touch /v/marker
    # What an operator might type: Compose takes the containers, never the external volumes.
    run instance_compose_of "$NAME" --profile '*' down -v
    assert_success
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    run docker run --rm -v "${NAME}_modality-simulator-data:/v:ro" alpine:3.21 ls /v
    assert_output marker
    run "$BIN/pihx" "$NAME" start
    assert_success
    refute_output --partial "Created volume"
}

@test "a bare docker compose up with the volumes missing fails, and creates none" {
    create modality-simulator
    run instance_compose_of "$NAME" up -d
    assert_failure
    assert_output --partial "external volume \"${NAME}_modality-simulator-data\" not found"
    run docker volume ls -q --filter "name=^${NAME}_"
    assert_output ''
    assert_equal "$(running)" ""
}

@test "start keeps using a volume Compose made before (an existing instance)" {
    create modality-simulator
    docker volume create --label "com.docker.compose.project=$NAME" \
        --label com.docker.compose.volume=modality-simulator-data "${NAME}_modality-simulator-data" >/dev/null
    docker run --rm -v "${NAME}_modality-simulator-data:/v" alpine:3.21 touch /v/marker
    run "$BIN/pihx" "$NAME" start
    assert_success
    refute_output --partial "Created volume"
    run docker exec "$NAME-modality-simulator" ls /data
    assert_output --partial marker
}

# --- archive -----------------------------------------------------------------------------------

@test "archive refuses a running instance" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    run "$BIN/pihx" "$NAME" archive
    assert_failure
    assert_output --partial "stop it first: pihx $NAME stop"
    run ls "$PIHX_HOME"
    refute_output --partial "$NAME.archive-"
    # A --to directory the launcher made for it goes again.
    run "$BIN/pihx" "$NAME" archive --to="$BATS_TEST_TMPDIR/new"
    assert_failure
    assert [ ! -e "$BATS_TEST_TMPDIR/new" ]
}

@test "archive writes every volume, owners kept, with the env files and RESTORE.txt, to --to" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    "$BIN/pihx" "$NAME" stop >/dev/null 2>&1
    docker run --rm -v "${NAME}_modality-simulator-data:/v" alpine:3.21 \
        sh -c 'echo hi > /v/f && chown 999:33 /v/f && chmod 640 /v/f'
    run "$BIN/pihx" "$NAME" archive --to "$BATS_TEST_TMPDIR/arch"
    assert_success
    assert_output --partial "Archived $NAME to $BATS_TEST_TMPDIR/arch/"
    run ls "$BATS_TEST_TMPDIR/arch"
    assert_output "$(printf '%s\n' RESTORE.txt instance.env modality-simulator.env \
        modality-simulator.override.yaml "${NAME}_modality-simulator-data.tar.gz")"
    run stat -c '%a' "$BATS_TEST_TMPDIR/arch" "$BATS_TEST_TMPDIR/arch/instance.env"
    assert_output $'700\n600'
    run tar -tzvf "$BATS_TEST_TMPDIR/arch/${NAME}_modality-simulator-data.tar.gz" --numeric-owner ./f
    assert_output --partial '-rw-r----- 999/33'
    # Not into a directory that isn't empty.
    run "$BIN/pihx" "$NAME" archive --to "$BATS_TEST_TMPDIR/arch"
    assert_failure
    assert_output --partial "isn't empty"
}

# --- destroy -----------------------------------------------------------------------------------

# Runs destroy on the instance, typing each of <answers> in turn.
destroy_typing() { # <answer>...
    run bash -c 'printf "%s\n" "${@:2}" | "$1" "$NAME" destroy' _ "$BIN/pihx" "$@"
}

destroyed() { ls -d "$PIHX_HOME/$NAME".destroyed-* 2>/dev/null; }

@test "destroy archives, then removes the instance's containers, volumes and directory, and nothing else" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    local other="$NAME-b"
    "$BIN/pihx" "$other" create --services=modality-simulator >/dev/null
    printf 'services:\n  modality-simulator:\n    init: true\n    command: ["sleep", "3600"]\n' \
        > "$PIHX_HOME/$other/modality-simulator.override.yaml"
    "$BIN/pihx" "$other" start >/dev/null 2>&1
    export NAME
    destroy_typing "$NAME" delete
    assert_success
    assert_output --partial "Removed instance directory $DIR"
    assert_output --partial "Removed volume ${NAME}_modality-simulator-data"
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    run docker volume ls -q --filter "name=^${NAME}_"
    assert_output ''
    assert [ ! -e "$DIR" ]
    assert [ -f "$(destroyed)/${NAME}_modality-simulator-data.tar.gz" ]
    assert_equal "$(docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$other")" "$other-modality-simulator"
    run docker volume inspect "${other}_modality-simulator-data"
    assert_success
    remove_test_instance "$other"
}

@test "destroy: anything but the name changes nothing; anything but delete keeps the volumes and the archive" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    export NAME
    for answers in "" "y" "$NAME-b"; do
        destroy_typing $answers
        assert_failure
        assert_output --partial "nothing was changed"
        assert_equal "$(running)" "$NAME-modality-simulator"
        assert_equal "$(destroyed)" ""
    done
    run bash -c "'$BIN/pihx' '$NAME' destroy < /dev/null"
    assert_failure
    assert_equal "$(running)" "$NAME-modality-simulator"
    destroy_typing "$NAME" no
    assert_failure
    assert_output --partial "nothing was deleted"
    assert_output --partial "pihx $NAME start"
    assert_equal "$(running)" ""
    assert [ -f "$DIR/instance.env" ]
    run docker volume inspect "${NAME}_modality-simulator-data"
    assert_success
    assert [ -f "$(destroyed)/RESTORE.txt" ]
    run "$BIN/pihx" "$NAME" destroy --force
    assert_failure 2
    assert_output --partial "destroy has no --force"
}

@test "destroy archives a removed service's volume, and RESTORE.txt brings it back" {
    create modality-simulator biometrics
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    docker run --rm -v "${NAME}_biometrics-data:/v" alpine:3.21 \
        sh -c 'echo kept > /v/f && chown 999:33 /v/f && chmod 640 /v/f'
    "$BIN/pihx" "$NAME" remove-service biometrics >/dev/null 2>&1
    export NAME
    destroy_typing "$NAME" delete
    assert_success
    assert_output --partial "Removed volume ${NAME}_biometrics-data"
    local archive
    archive=$(destroyed)
    assert [ -f "$archive/${NAME}_biometrics-data.tar.gz" ]
    run stat -c '%a' "$archive" "$archive/modality-simulator.env" "$archive/RESTORE.txt"
    assert_output $'700\n600\n600'
    # Its commands, but the last (pihx start), as written.
    sed -n '/^  mkdir/,$p' "$archive/RESTORE.txt" | grep -v '^  pihx ' > "$BATS_TEST_TMPDIR/restore.sh"
    run bash -e "$BATS_TEST_TMPDIR/restore.sh"
    assert_success
    run docker run --rm -v "${NAME}_biometrics-data:/v:ro" alpine:3.21 stat -c '%u:%g %a %n' /v/f
    assert_output '999:33 640 /v/f'
    run "$BIN/pihx" "$NAME" start
    assert_success
    assert_equal "$(running)" "$NAME-modality-simulator"
}

@test "destroy with PIHX_HOME not writable changes nothing" {
    # Its own PIHX_HOME: the run's is shared by the tests running alongside this one.
    export PIHX_HOME="$BATS_TEST_TMPDIR/home"
    DIR="$PIHX_HOME/$NAME"
    mkdir "$PIHX_HOME"
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    export NAME
    chmod 555 "$PIHX_HOME"
    destroy_typing "$NAME" delete
    chmod 755 "$PIHX_HOME"
    assert_failure
    assert_output --partial "can't write the archive"
    assert_equal "$(running)" "$NAME-modality-simulator"
    assert [ -f "$DIR/instance.env" ]
}

@test "a job's kept container and volume go with destroy" {
    create openmrs-db petl
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    export NAME
    destroy_typing "$NAME" delete
    assert_success
    assert_output --partial "Removed volume ${NAME}_petl-data"
    assert [ ! -e "$DIR" ]
}

@test "destroy removes everything even when Compose can't read the instance" {
    create modality-simulator
    "$BIN/pihx" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running)" "$NAME-modality-simulator"
    echo 'services: [' > "$DIR/modality-simulator.override.yaml"   # Compose can't read it
    export NAME
    destroy_typing "$NAME" delete
    assert_success
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    run docker volume ls -q --filter "name=^${NAME}_"
    assert_output ''
    assert [ ! -e "$DIR" ]
}

@test "destroy removes root-owned files a container left in the instance directory" {
    create modality-simulator
    docker run --rm -v "$DIR:/d" alpine:3.21 sh -c 'mkdir /d/out && touch /d/out/report && chmod 700 /d/out'
    export NAME
    destroy_typing "$NAME" delete
    assert_success
    assert [ ! -e "$DIR" ]
}
