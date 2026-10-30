#!/usr/bin/env bats
# Adding and removing services, run-service, and destroy, through openmrs-docker, with two light
# services in place of the real ones: modality-simulator ("keep") and biometrics ("gone"), given
# alpine as their image and an override file that makes it sleep.

load ../helpers

setup() {
    NAME="$(instance)"
    DIR="$PIHX_HOME/$NAME"
    MODALITY_SIMULATOR_IMAGE_NAME=alpine MODALITY_SIMULATOR_IMAGE_TAG=3.21 \
        MODALITY_SIMULATOR_GATEWAY_AE=GW MODALITY_SIMULATOR_HOST_PORT=0 MODALITY_SIMULATOR_IMAGE_DIR=/tmp \
        BIOMETRICS_IMAGE_NAME=alpine BIOMETRICS_IMAGE_TAG=3.21 BIOMETRICS_LICENSE_BASE64=eA== \
        create_instance "$NAME" --services=modality-simulator,biometrics 2>/dev/null
    local svc
    for svc in modality-simulator biometrics; do
        printf 'services:\n  %s:\n    init: true\n    command: ["sleep", "300"]\n' "$svc" > "$DIR/$svc.override.yaml"
    done
}
teardown() {
    destroy_instance "$NAME"
    common_teardown
}

running() { docker ps -q --filter "label=com.docker.compose.project=$NAME"; }

@test "remove-service on a stopped instance leaves it stopped" {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    "$BIN/openmrs-docker" "$NAME" stop >/dev/null 2>&1
    run "$BIN/openmrs-docker" "$NAME" remove-service biometrics
    assert_success
    assert_equal "$(running)" ""
    [ ! -e "$DIR/biometrics.env" ]
}

@test "remove-service on a running instance removes only that service's containers, and keeps its volumes" {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    local keep_id
    keep_id=$(docker ps -q --filter "name=^$NAME-modality-simulator$")
    run "$BIN/openmrs-docker" "$NAME" remove-service biometrics
    assert_success
    assert_output --partial "its volumes are kept"
    assert_equal "$(docker ps -aq --filter "name=^$NAME-biometrics$")" ""
    assert_equal "$(docker ps -q --filter "name=^$NAME-modality-simulator$")" "$keep_id"
    run docker volume inspect "${NAME}_biometrics-data"
    assert_success
}

@test "remove-service refuses when what's left would be broken, and keeps the service" {
    local other
    other="$(instance other)"
    create_instance "$other" --services=openmrs-db,openmrs 2>/dev/null
    # openmrs requires openmrs-db
    run "$BIN/openmrs-docker" "$other" remove-service openmrs-db
    assert_failure
    assert_output --partial "openmrs requires openmrs-db"
    [ -e "$PIHX_HOME/$other/openmrs-db.env" ]
    destroy_instance "$other"
}

@test "run-service runs a profiled container once with the given command, and start leaves it alone" {
    cat >> "$DIR/modality-simulator.override.yaml" <<'YAML'
  job:
    image: alpine:3.21
    profiles: ["job"]
YAML
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running | wc -l)" 2
    run "$BIN/openmrs-docker" "$NAME" run-service job echo "hello from job"
    assert_success
    assert_output --partial 'hello from job'
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.service=job" --filter "label=com.docker.compose.project=$NAME")" ""
    run "$BIN/openmrs-docker" "$NAME" run-service nope
    assert_failure
    assert_output --partial "nope not present on $NAME"
}

@test "destroy removes everything even when the compose files no longer interpolate" {
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1
    assert_equal "$(running | wc -l)" 2
    # shellcheck disable=SC2016 # for Compose to interpolate
    printf 'services:\n  modality-simulator:\n    image: alpine:${NOT_SET_ANYWHERE?}\n' > "$DIR/modality-simulator.override.yaml"
    run "$BIN/openmrs-docker" "$NAME" destroy --force
    assert_success
    # (pihx-runtime's Compose brings the project down by its label itself, so pihx's own fallback
    # by label, which says so, isn't always reached; either way everything goes.)
    assert_equal "$(docker ps -aq --filter "label=com.docker.compose.project=$NAME")" ""
    assert_equal "$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME")" ""
    [ ! -e "$DIR" ]
}

@test "destroy removes root-owned files a container left in the instance directory" {
    docker run --rm -v "$DIR:/d" alpine:3.21 sh -c 'mkdir /d/out && touch /d/out/report && chmod 700 /d/out'
    run "$BIN/openmrs-docker" "$NAME" destroy --force
    assert_success
    [ ! -e "$DIR" ]
}
