#!/bin/bash
# General-purpose: strips DEFINER=`user`@`host` clauses from a mysqldump SQL file (plain .sql or
# gzip-compressed .sql.gz), producing a modified copy -- the original is never touched. A
# routine/trigger/view created with a DEFINER account that doesn't exist on the restore target
# can fail at execution time (not creation time), often surfacing well after the restore looked
# successful; removing the clause leaves MySQL to default the definer to whichever user performs
# the restore instead. This is a separate, optional step -- run it against a dump only if/when you
# actually hit that problem, then feed the result to `initialize`'s RESTORE_MYSQL_DUMP_PATH in
# place of the original. mysqldump itself has no flag to omit DEFINER, hence the text rewrite.
# Usage:
#   utils/strip-mysqldump-definers.sh --path=<dump.sql|dump.sql.gz> --output=<path>
#
# --output's extension controls the output format independently of the input's: a plain .sql in,
# a gzip-compressed .sql.gz out (or vice versa) both work.
set -euo pipefail

SRC=
OUTPUT_PATH=
for arg in "$@"; do
    case "$arg" in
        --path=*) SRC="${arg#*=}" ;;
        --output=*) OUTPUT_PATH="${arg#*=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
usage() { echo "usage: $0 --path=<dump.sql|dump.sql.gz> --output=<path>" >&2; exit 1; }
[ -z "$SRC" ] && usage
[ -z "$OUTPUT_PATH" ] && usage
[ -f "$SRC" ] || { echo "error: no such file: $SRC" >&2; exit 1; }

case "$OUTPUT_PATH" in
    /*) ;;
    *) OUTPUT_PATH="$(pwd)/$OUTPUT_PATH" ;;
esac
[ -e "$OUTPUT_PATH" ] && { echo "error: $OUTPUT_PATH already exists" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT_PATH")"

case "$SRC" in
    *.gz) READ_CMD=(zcat "$SRC") ;;
    *)    READ_CMD=(cat "$SRC") ;;
esac

echo "Stripping DEFINER clauses from $SRC into $OUTPUT_PATH..."
case "$OUTPUT_PATH" in
    *.gz) "${READ_CMD[@]}" | sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g' | gzip > "$OUTPUT_PATH" ;;
    *)    "${READ_CMD[@]}" | sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g' > "$OUTPUT_PATH" ;;
esac
echo "Wrote $OUTPUT_PATH."
