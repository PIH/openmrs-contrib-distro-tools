#!/bin/bash
# Copies a mysqldump file without its DEFINER=`user`@`host` clauses, so its routines, triggers and
# views work on a server without those accounts (they'd fail when run, not when restored). For a
# new dump, backup-mysqldump --strip-definers does this as it dumps.
#
# Usage: openmrs-utils strip-mysqldump-definers --path=<dump.sql | dump.sql.gz> --output=<file>
#   --output  ending in .gz for a gzipped copy, otherwise plain SQL (from either kind of input)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/mysql.sh
. "$UTILS_DIR/lib/mysql.sh"

SRC=
OUTPUT=
for arg in "$@"; do
    case "$arg" in
        --path=*) SRC="${arg#*=}" ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$SRC" ] && [ -n "$OUTPUT" ] || usage
[ -f "$SRC" ] || die "no such file: $SRC"
OUTPUT=$(abs_path "$OUTPUT")
prepare_output_file "$OUTPUT"

case "$SRC" in
    *.gz) READ=(zcat "$SRC") ;;
    *) READ=(cat "$SRC") ;;
esac
note "Stripping DEFINER clauses from $SRC into $OUTPUT..."
case "$OUTPUT" in
    *.gz) "${READ[@]}" | strip_definers | gzip > "$OUTPUT" ;;
    *) "${READ[@]}" | strip_definers > "$OUTPUT" ;;
esac
note "Wrote $OUTPUT."
