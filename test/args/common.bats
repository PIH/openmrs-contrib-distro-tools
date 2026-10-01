#!/usr/bin/env bats
# utils/lib/common.sh: a script that fails says so, even when the command that failed printed no
# error of its own, and says what it removed.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() { common_teardown; }

# Writes a script that sources common.sh, starts <output> with prepare_output_file, then runs <body>.
script() { # <output> <body>
    printf '#!/bin/bash\nset -euo pipefail\n. %q\nprepare_output_file %q\necho partial > %q\n%s\n' \
        "$UTILS/lib/common.sh" "$1" "$1" "$2" > s.sh
    chmod +x s.sh
}

@test "a command failing without a message of its own gets an error line naming the script" {
    script "$BATS_TEST_TMPDIR/out.7z" false
    run ./s.sh
    assert_failure
    assert_output --partial 'error: s failed (exit status 1)'
    assert_output --partial "Removed the incomplete $BATS_TEST_TMPDIR/out.7z"
    assert [ ! -e out.7z ]
}

@test "die's error isn't followed by a second one" {
    script out.7z 'die "bad input"'
    run ./s.sh
    assert_failure
    assert_line --index 0 'error: bad input'
    refute_output --partial 'failed (exit status'
    assert [ ! -e out.7z ]
}

@test "a successful run removes nothing and prints nothing" {
    script out.7z true
    run ./s.sh
    assert_success
    assert_output ''
    assert [ -e out.7z ]
}
