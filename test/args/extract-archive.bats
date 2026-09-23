#!/usr/bin/env bats
# extract-archive's input handling. Actual extraction is covered by the integration round trips.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

@test "requires --path" {
    run "$UTILS/extract-archive.sh"
    assert_failure
    assert_output --partial usage
}

@test "prints a non-archive path unchanged, so callers can pass either" {
    touch dump.sql
    run "$UTILS/extract-archive.sh" --path=dump.sql
    assert_success
    assert_output dump.sql
}

@test "rejects a path that doesn't exist" {
    run "$UTILS/extract-archive.sh" --path=nope.tar.gz
    assert_failure
    assert_output --partial 'no such file or directory'
}

@test "fails if an archive has more than one top-level entry" {
    mkdir -p two/a two/b
    tar czf two.tar.gz -C two a b
    run "$UTILS/extract-archive.sh" --path=two.tar.gz --output-dir="$BATS_TEST_TMPDIR/out"
    assert_failure
    assert_output --partial 'produced 2 top-level entries, expected exactly 1'
}

@test "extracts into a relative --output-dir, not a Docker volume of that name" {
    mkdir -p src/data
    echo x > src/data/f
    tar czf data.tar.gz -C src data
    # Prefixed, so teardown also removes a stray Docker volume of this name if one gets created.
    local out
    out="$(res out)"
    run --separate-stderr "$UTILS/extract-archive.sh" --path=data.tar.gz --output-dir="$out"
    assert_success
    assert_equal "$(cd "$output" && pwd)" "$BATS_TEST_TMPDIR/$out/data"
    assert_equal "$(cat "$out/data/f")" x
    run docker volume inspect "$out"
    assert_failure
}
