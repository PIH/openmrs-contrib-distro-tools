#!/usr/bin/env bats
# Images built from this repo are referenced by partnersinhealth/<name>:<content tag>, the tag CI
# publishes (build-images.yml), and never by `latest`.

load ../helpers

@test "images are referenced by their content tag" {
    local file
    for file in bin/pihx test/run; do
        run grep -F 'partnersinhealth/pihx-runtime:$(' "$REPO_ROOT/$file"
        assert_success
        run grep -F 'images/pihx-runtime' "$REPO_ROOT/$file"
        assert_success
        run grep -E 'pihx-runtime:latest' "$REPO_ROOT/$file"
        assert_failure
    done
    run grep -E '(^|[^/])pihx-runtime:\$\(' "$REPO_ROOT/bin/pihx" "$REPO_ROOT/test/run"
    assert_failure
}

@test "every directory under images/ has a Dockerfile" {
    local dir
    for dir in "$REPO_ROOT"/images/*/; do
        [ -f "$dir/Dockerfile" ] || fail "$dir has no Dockerfile"
    done
}

@test "build-images pushes only on a push to main" {
    local script
    script=$(python3 -c 'import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in w["jobs"]["build"]["steps"] if s.get("id") == "images"))' \
        "$REPO_ROOT/.github/workflows/build-images.yml")
    run grep -F "PUSH: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}" \
        "$REPO_ROOT/.github/workflows/build-images.yml"
    assert_success
}
