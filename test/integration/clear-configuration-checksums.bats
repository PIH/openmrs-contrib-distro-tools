#!/usr/bin/env bats
# clear-configuration-checksums removes only configuration_checksums, and never from a volume in use.

load ../helpers

setup() {
    VOL="$(res data)"
    docker volume create "$VOL" >/dev/null
    docker run --rm -v "$VOL:/v" alpine:3.21 sh -c \
        'mkdir -p /v/configuration_checksums /v/modules && touch /v/configuration_checksums/a.checksum /v/modules/a.omod /v/openmrs-runtime.properties'
}
teardown() { common_teardown; }

@test "removes configuration_checksums and nothing else" {
    run "$UTILS/clear-configuration-checksums.sh" --volume="$VOL"
    assert_success
    run tree_of_volume "$VOL"
    assert_output "./modules
./modules/a.omod
./openmrs-runtime.properties"
}

@test "refuses while a running container has the volume mounted, leaving it untouched" {
    docker run -d --name "$(res user)" -v "$VOL:/openmrs/data" alpine:3.21 sleep 300 >/dev/null
    run "$UTILS/clear-configuration-checksums.sh" --volume="$VOL"
    assert_failure
    assert_output --partial 'in use by a running container'
    run tree_of_volume "$VOL"
    assert_line ./configuration_checksums/a.checksum
}

@test "rejects a volume that doesn't exist, without creating it" {
    run "$UTILS/clear-configuration-checksums.sh" --volume="$(res missing)"
    assert_failure
    assert_output --partial 'no such volume'
    run docker volume inspect "$(res missing)"
    assert_failure
}
