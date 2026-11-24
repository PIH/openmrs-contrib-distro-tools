#!/bin/bash
# dhis2-test-copy (compose.yaml), at each pihx start or update, once dhis2-db is healthy: on an
# instance marked as a copy of production (DHIS2_TEST_COPY=true), turns off outbound email, SMS
# gateways, the remote sync target and the jobs that send data out or message people
# (test-copy.sql). Each pihx start, so an admin who turns them back on in a training doesn't keep them;
# not a reboot, where restart: unless-stopped brings dhis2 back without it (README.md).
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

# Notices (none expected) would only be noise: warnings and errors still show, as their SQL state
# only (VERBOSITY=sqlstate): a message can quote a row's values, and on a copy of production those are
# patients'. test-copy.sql's own checks raise PX001, PX002 and PX003 (it says which is which).
if ! PGOPTIONS='-c client_min_messages=warning' psql -X -q -1 -v ON_ERROR_STOP=1 \
        -v VERBOSITY=sqlstate -v SHOW_CONTEXT=never \
        -h dhis2-db -U "${DHIS2_DB_USER:?}" -d "${DHIS2_DB_NAME:?}" -f /test-copy.sql; then
    echo "error: dhis2-test-copy: test-copy.sql failed with the SQL state above (PX001, PX002, PX003: a schema it doesn't know; see test-copy.sql), and changed nothing" >&2
    exit 1
fi
echo "dhis2-test-copy: outbound email and sending jobs turned off"
