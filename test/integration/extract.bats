#!/usr/bin/env bats
# utils/lib/in-container/extract.sh, which extract-archive and initialize's restore overlays use,
# with every format they take.

load ../helpers

# Archives of src/ (top/ holding a file and a dotfile), each format, made in the p7zip image.
setup_file() {
    local w="$BATS_FILE_TMPDIR/w"
    mkdir -p "$w/src/top" && echo a > "$w/src/top/a" && echo h > "$w/src/top/.h" && echo f > "$w/src/flat"
    docker run --rm -v "$w:/w" -w /w/src "$P7ZIP_IMAGE" sh -c '
        7z a -ppw /w/top.7z top >/dev/null && 7z a -tzip /w/top.zip top >/dev/null &&
        tar czf /w/top.tar.gz top && cp /w/top.tar.gz /w/top.tgz && tar cf /w/top.tar top &&
        7z a -tzip /w/flat.zip top flat >/dev/null'
    export W="$w"
}
teardown_file() { common_teardown_file; }
teardown() { common_teardown; }

extract() { # <source in $W> [--print-root]; prints extract.sh's output, then what it extracted
    docker run --rm -e ARCHIVE_PASSWORD -v "$W:/w:ro" -v "$UTILS/lib/in-container/extract.sh:/extract.sh:ro" \
        "$P7ZIP_IMAGE" sh -c 'sh /extract.sh "/w/$1" /out "$2" && cd /out && find . -type f | LC_ALL=C sort' sh "$@"
}

@test "every archive format extracts, and --print-root finds its single top-level folder" {
    local f
    for f in top.zip top.tar.gz top.tgz top.tar; do
        run extract "$f" --print-root
        assert_success
        assert_output "$(printf '/out/top\n./top/.h\n./top/a')"
    done
    ARCHIVE_PASSWORD=pw run extract top.7z --print-root
    assert_success
    assert_output "$(printf '/out/top\n./top/.h\n./top/a')"
}

@test "--print-root gives the directory itself for an archive with more than one entry" {
    run extract flat.zip --print-root
    assert_success
    assert_output "$(printf '/out\n./flat\n./top/.h\n./top/a')"
}

@test "a directory is copied, dotfiles included" {
    run extract src/top
    assert_success
    assert_output "$(printf './.h\n./a')"
}

@test "a protected .7z fails cleanly with a wrong or missing password" {
    ARCHIVE_PASSWORD=wrong run extract top.7z
    assert_failure
    assert_output --partial 'Wrong password'
    unset ARCHIVE_PASSWORD
    run extract top.7z
    assert_failure
}
