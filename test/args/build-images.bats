#!/usr/bin/env bats
# The build step of build-images.yml, run with a stub docker: which images it builds, pushes and
# moves `latest` for. A tag that exists is never built or pushed again.

load ../helpers

setup() {
    export STUB_LOG="$BATS_TEST_TMPDIR/docker.log"
    : > "$STUB_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/repo/images/a" "$BATS_TEST_TMPDIR/repo/images/b" \
        "$BATS_TEST_TMPDIR/repo/services/s/image" "$BATS_TEST_TMPDIR/repo/lib"
    cd "$BATS_TEST_TMPDIR/repo"
    echo a > images/a/Dockerfile; echo b > images/b/Dockerfile; echo s > services/s/image/Dockerfile
    cp "$REPO_ROOT/lib/image-tag.sh" lib/
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
# `manifest inspect <image>` succeeds for the images in STUB_EXISTING (space-separated).
if [ "$1 $2" = "manifest inspect" ]; then
    for e in $STUB_EXISTING; do [ "$e" = "$3" ] && exit 0; done
    echo "Error: no such manifest: $3" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    # Docker Hub's repository API: STUB_REPO_CODE is its HTTP status (default 200), STUB_CURL_FAIL=1 a failed request.
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >> "$STUB_LOG"
[ -z "${STUB_CURL_FAIL:-}" ] || exit 6
printf '%s' "${STUB_REPO_CODE:-200}"
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    script="$(python3 -c 'import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in w["jobs"]["build"]["steps"] if s.get("id") == "images"))' \
        "$REPO_ROOT/.github/workflows/build-images.yml")"
}

tag() { lib/image-tag.sh "$1"; }
build() { run bash -c "$script"; }

@test "build-images never overwrites a tag: an existing tag is neither built nor pushed" {
    PUSH=true STUB_EXISTING="partnersinhealth/a:$(tag images/a)" build
    assert_success
    run grep -E "^(buildx )?build .*-t partnersinhealth/a:" "$STUB_LOG"
    assert_failure
}

@test "build-images pushes a missing tag, then moves latest, on main" {
    PUSH=true STUB_EXISTING="" build
    assert_success
    run cat "$STUB_LOG"
    assert_line --regexp "^buildx build .*--push .*-t partnersinhealth/a:$(tag images/a) .*images/a\$"
    assert_line --regexp "^buildx imagetools create -t partnersinhealth/a:latest partnersinhealth/a:$(tag images/a)\$"
    assert_line --regexp "^buildx build .*--push .*-t partnersinhealth/s:$(tag services/s/image) .*services/s/image\$"
}

@test "build-images builds without pushing, and leaves latest alone, off main" {
    PUSH=false STUB_EXISTING="" build
    assert_success
    run cat "$STUB_LOG"
    assert_line --regexp "^build .*images/a\$"
    refute_output --partial "--push"
    refute_output --partial "imagetools"
}

@test "build-images still moves latest to an existing tag on main" {
    PUSH=true STUB_EXISTING="partnersinhealth/a:$(tag images/a)" build
    assert_success
    run cat "$STUB_LOG"
    assert_line --regexp "^buildx imagetools create -t partnersinhealth/a:latest partnersinhealth/a:$(tag images/a)\$"
}

@test "build-images stops when a build fails, without moving latest for it" {
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ "$1 $2" = "manifest inspect" ] && { echo "no such manifest" >&2; exit 1; }
[ "$1 $2" = "buildx build" ] && exit 1
exit 0
STUB
    PUSH=true build
    assert_failure
    run cat "$STUB_LOG"
    refute_output --partial "imagetools"
}

@test "build-images fails, without building or pushing, when the manifest check fails for another reason" {
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ "$1 $2" = "manifest inspect" ] && { printf "errors:\\ndenied: requested access to the resource is denied\\n" >&2; exit 1; }
exit 0
STUB
    RETRY_DELAY=0 PUSH=true build
    assert_failure
    assert_output --partial "Can't tell whether"
    run cat "$STUB_LOG"
    refute_output --partial "build"
    refute_output --partial "imagetools"
    assert_equal "$(grep -c 'manifest inspect' "$STUB_LOG")" 3
}

@test "build-images builds and pushes when the repository doesn't exist yet (denied, and Hub says 404)" {
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ "$1 $2" = "manifest inspect" ] && { printf 'errors:\ndenied: requested access to the resource is denied\n' >&2; exit 1; }
exit 0
STUB
    RETRY_DELAY=0 STUB_REPO_CODE=404 PUSH=true build
    assert_success
    run cat "$STUB_LOG"
    assert_line --regexp "^buildx build .*--push .*-t partnersinhealth/a:$(tag images/a) "
    assert_line --regexp "^curl .*hub.docker.com/v2/repositories/partnersinhealth/a/"
}

@test "build-images fails, without pushing, when the repository check itself fails" {
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ "$1 $2" = "manifest inspect" ] && { printf 'errors:\ndenied: requested access to the resource is denied\n' >&2; exit 1; }
exit 0
STUB
    RETRY_DELAY=0 STUB_CURL_FAIL=1 PUSH=true build
    assert_failure
    assert_output --partial "Can't tell whether"
    run cat "$STUB_LOG"
    refute_output --partial "build"
}

@test "build-images doesn't take a bare 'not found' for a missing tag, and bounds the repository check" {
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
[ "$1 $2" = "manifest inspect" ] && { echo "error: registry mirror not found" >&2; exit 1; }
exit 0
STUB
    RETRY_DELAY=0 STUB_REPO_CODE=200 PUSH=true build
    assert_failure
    assert_output --partial "Can't tell whether"
    run cat "$STUB_LOG"
    refute_output --partial "buildx build"
    assert_line --regexp "^curl .*--max-time 30 "
}
