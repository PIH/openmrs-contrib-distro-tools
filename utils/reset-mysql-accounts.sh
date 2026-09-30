#!/bin/bash
# Sets a stopped MySQL/MariaDB data directory's root and --user passwords without knowing the
# current ones: for a data directory restored from another server's physical backup, whose accounts
# came with it, or to rotate an instance's passwords. lib/in-container/reset-mysql-accounts.sh,
# which does the work, lists exactly what it changes.
#
# Usage: openmrs-utils reset-mysql-accounts --volume=<volume or dir> [--image=mysql:5.6]
#            [--user=openmrs] [--database=openmrs]
#   --volume             the data directory: a volume, or an absolute path (refused while in use)
#   --image              the server image the data directory belongs to (its version)
#   --user, --database   the application account, and the database it gets all privileges on
#   MYSQL_ROOT_PASSWORD  the new root password (required)
#   MYSQL_PASSWORD       the new --user password (required)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VOLUME=
IMAGE=mysql:5.6
DB_USER=openmrs
DB_NAME=openmrs
for arg in "$@"; do
    case "$arg" in
        --volume=*) VOLUME="${arg#*=}" ;;
        --image=*) IMAGE="${arg#*=}" ;;
        --user=*) DB_USER="${arg#*=}" ;;
        --database=*) DB_NAME="${arg#*=}" ;;
        *) die "unknown argument: $arg" ;;
    esac
done
[ -n "$VOLUME" ] || usage
[ -n "${MYSQL_ROOT_PASSWORD:-}" ] || die "MYSQL_ROOT_PASSWORD (the new root password) must be set"
[ -n "${MYSQL_PASSWORD:-}" ] || die "MYSQL_PASSWORD (the new password for --user) must be set"
refuse_if_in_use "$VOLUME" "two servers on one data directory corrupt it"

RESET_DB_USER="$DB_USER" RESET_DB_NAME="$DB_NAME" docker run --rm \
    -e MYSQL_ROOT_PASSWORD -e MYSQL_PASSWORD -e RESET_DB_USER -e RESET_DB_NAME \
    -v "$VOLUME:/var/lib/mysql" \
    -v "$UTILS_DIR/lib/in-container/reset-mysql-accounts.sh:/reset-mysql-accounts.sh:ro" \
    --entrypoint bash "$IMAGE" /reset-mysql-accounts.sh
