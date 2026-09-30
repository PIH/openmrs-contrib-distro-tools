#!/usr/bin/env bats
# extract-archive's input handling. Actual extraction is covered by the integration round trips.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

@test "requires --path" {
    run "$UTILS/extract-archive.sh"
    assert_failure
    assert_output --partial Usage:
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

@test "a flat archive (more than one top-level entry) extracts to, and prints, the output directory" {
    mkdir -p flat/a && echo x > flat/f1 && echo y > flat/a/f2
    tar czf flat.tar.gz -C flat f1 a
    run --separate-stderr "$UTILS/extract-archive.sh" --path=flat.tar.gz --output-dir="$BATS_TEST_TMPDIR/out"
    assert_success
    assert_output "$BATS_TEST_TMPDIR/out"
    assert_equal "$(cat out/f1)" x
    assert_equal "$(cat out/a/f2)" y
}

@test "a flat .7z extracts to a new temporary directory when there's no --output-dir" {
    mkdir -p flat && echo x > flat/f1 && echo y > flat/f2
    docker run --rm -v "$BATS_TEST_TMPDIR/flat:/w" -w /w partnersinhealth/p7zip 7z a -ppw /w/flat.7z f1 f2 >/dev/null
    ARCHIVE_PASSWORD=pw run --separate-stderr "$UTILS/extract-archive.sh" --path=flat/flat.7z
    assert_success
    assert [ -f "$output/f1" ]
    assert [ -f "$output/f2" ]
    reclaim "$output"; rm -rf "$output"
}

@test "refuses before extracting when the output's filesystem hasn't room for the contents" {
    mkdir -p src/data && head -c 2097152 /dev/urandom > src/data/random
    tar czf data.tar.gz -C src data
    DISK_SPACE_FREE_KB=100 run "$UTILS/extract-archive.sh" --path=data.tar.gz --output-dir="$BATS_TEST_TMPDIR/out"
    assert_failure
    assert_output --partial "not enough disk space"
    assert_output --partial "needs about 2.0M"
    [ ! -e out ]
    DISK_SPACE_FREE_KB=100 SKIP_DISK_SPACE_CHECK=true run --separate-stderr "$UTILS/extract-archive.sh" --path=data.tar.gz --output-dir="$BATS_TEST_TMPDIR/out"
    assert_success
    assert_output "$BATS_TEST_TMPDIR/out/data"
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

@test "a .tar.gz of files with long runs of zeros extracts (busybox tar's own gzip detection can't)" {
    mkdir -p src/data && head -c 2097152 /dev/zero > src/data/zeros
    tar czf data.tar.gz -C src data
    run --separate-stderr "$UTILS/extract-archive.sh" --path=data.tar.gz --output-dir="$BATS_TEST_TMPDIR/out"
    assert_success
    assert_equal "$(stat -c %s out/data/zeros)" 2097152
}
