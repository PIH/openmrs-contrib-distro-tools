#!/bin/bash
# dhis2-test-copy (compose.yaml), before every start of dhis2, once dhis2-db is healthy: on an
# instance marked as a copy of production (DHIS2_TEST_COPY=true), turns off outbound email, SMS
# gateways, the remote sync target and the jobs that send data out or message people
# (test-copy.sql). Every start, so an admin who turns them back on in a training doesn't keep them.
# On any other instance it changes nothing. The password reaches psql as PGPASSWORD, from the
# environment; nothing here prints a value.
set -euo pipefail

case ${DHIS2_TEST_COPY:-false} in
    true) ;;
    false)
        echo "dhis2-test-copy: not a test copy, nothing changed"
        exit 0 ;;
    *)
        # A typo mustn't leave a copy of production able to send.
        echo "error: DHIS2_TEST_COPY must be true or false" >&2
        exit 1 ;;
esac

# Notices (none expected) would only be noise: warnings and errors still show.
PGOPTIONS='-c client_min_messages=warning' psql -X -q -1 -v ON_ERROR_STOP=1 \
    -h dhis2-db -U "${DHIS2_DB_USER:?}" -d "${DHIS2_DB_NAME:?}" -f /test-copy.sql
echo "dhis2-test-copy: outbound email and sending jobs turned off"
