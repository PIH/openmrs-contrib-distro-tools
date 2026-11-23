#!/bin/bash
# Reads DHIS2's log on stdin and prints only what names a failed Flyway migration: the migration's
# version and description, its file, and the SQL state, one per line, in log order, each once.
# Nothing else from the log, ever: Postgres errors quote row values (e.g. "Key (id)=(...)"), and this
# output is meant to be relayed off the machine. Each value is matched to the characters it's made of,
# so a line that also holds anything else prints nothing. Used by commands/upgrade; tested in
# test/args/dhis2-upgrade.bats.
set -euo pipefail
sed -n -E \
    -e 's/^.*Migration of schema "[A-Za-z0-9_]+" to version "([A-Za-z0-9._ -]+)" failed.*$/  migration \1 failed/p' \
    -e 's/^.*Migration (V[A-Za-z0-9._]+\.sql) failed[[:space:]]*$/  migration \1 failed/p' \
    -e 's/^SQL State[[:space:]]*:[[:space:]]*([A-Z0-9]{5})[[:space:]]*$/  SQL state \1/p' |
    awk '!seen[$0]++'
