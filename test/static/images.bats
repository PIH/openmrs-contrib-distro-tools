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

@test "pihx-runtime installs only the packages the dependency policy allows" {
    # docs/development.md#dependencies: adding a package is a team decision, and an allowed import in
    # pihx/tests/test_imports.py.
    run grep -xF 'RUN apk add --no-cache python3 py3-yaml docker-cli-compose bash' \
        "$REPO_ROOT/images/pihx-runtime/Dockerfile"
    assert_success
}

@test "pip in pihx-runtime installs only exact versions" {
    # docs/development.md#dependencies: pip only in this Dockerfile, each package as name==version
    # (so no requirements files or other indexes either). Continued lines are joined first.
    local unpinned
    unpinned=$(awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }' "$REPO_ROOT/images/pihx-runtime/Dockerfile" \
        | grep -oE 'pip3? install[^&;|]*' | tr ' \t' '\n\n' | grep . \
        | grep -vxE 'pip3?|install|--no-cache-dir|--break-system-packages' | grep -vF '==' || true)
    [ -z "$unpinned" ] || fail "pip installs without an exact version: $unpinned"
}

@test "build-images pushes only on a push to main" {
    run grep -F "PUSH: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}" \
        "$REPO_ROOT/.github/workflows/build-images.yml"
    assert_success
}
