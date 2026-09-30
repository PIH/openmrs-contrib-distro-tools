#!/bin/bash
# General-purpose: sets a stopped MySQL/MariaDB data directory's accounts to the given passwords,
# without knowing the current ones. For a data directory restored from another server's physical
# backup (its accounts come with it), or to rotate an instance's passwords. Usage:
#   utils/reset-mysql-accounts.sh --volume=<db data volume or host dir> [--image=mysql:5.6]
#       [--user=openmrs] [--database=openmrs]
#
# Starts --image's server on the data directory with --skip-grant-tables --skip-networking (so no
# password is needed, and nothing can connect from outside), then:
#   - sets the password of every root@<host> account, and creates root@'%' if missing;
#   - sets the password of every <--user>@<host> account, and creates <--user>@'%' with all
#     privileges on --database if missing (a host-specific account such as a legacy
#     openmrs@localhost would otherwise still win over '%' for local logins, with its old password);
#   - removes anonymous accounts (''@<host>), which would also win over '%' for local logins;
#   - keeps every other account, and lists them.
# The same accounts a new instance gets from the image's MYSQL_ROOT_PASSWORD / MYSQL_USER.
#
# MYSQL_ROOT_PASSWORD and MYSQL_PASSWORD (env vars, not arguments -- secrets) are the new root and
# --user passwords; both required. They reach the container as bare `-e` names, so they never
# appear in `docker`'s argv. --volume is passed straight through as `docker run -v`'s source, like
# backup-percona's. Refuses to run while a container is using --volume: two servers on one data
# directory corrupt it. --image should be the one the instance runs (the data directory's version).
#
# --in-container is for running inside such an image with the data directory at /var/lib/mysql
# (as openmrs-docker initialize's restore overlay does); the user and database then come from
# RESET_DB_USER / RESET_DB_NAME.
set -euo pipefail

if [ "${1:-}" = --in-container ]; then
    : "${MYSQL_ROOT_PASSWORD:?}" "${MYSQL_PASSWORD:?}"
    DB_USER="${RESET_DB_USER:-openmrs}" DB_NAME="${RESET_DB_NAME:-openmrs}"
    SERVER=mysqld; command -v mariadbd >/dev/null && SERVER=mariadbd
    CLIENT=mysql; command -v mysql >/dev/null || CLIENT=mariadb
    SOCKET=/tmp/reset-mysql-accounts.sock
    "$SERVER" --user=mysql --datadir=/var/lib/mysql --skip-grant-tables --skip-networking \
        --socket="$SOCKET" --pid-file=/tmp/reset-mysql-accounts.pid --log-error=/tmp/reset-mysql-accounts.err \
        >/dev/null 2>&1 &
    PID=$!
    # A large restored data directory can spend a long time in crash recovery first.
    until "$CLIENT" --socket="$SOCKET" -uroot -e 'SELECT 1' >/dev/null 2>&1; do
        kill -0 "$PID" 2>/dev/null || { cat /tmp/reset-mysql-accounts.err >&2; echo "error: the server didn't start" >&2; exit 1; }
        sleep 1
    done
    sql() { "$CLIENT" --socket="$SOCKET" -uroot -N -B -e "$1"; }
    lit() { local v=${1//\\/\\\\}; printf "'%s'" "${v//\'/\\\'}"; }   # a quoted SQL string literal
    # Everything is read first: once FLUSH PRIVILEGES loads the grant tables (which account
    # statements need under --skip-grant-tables), new connections have to log in, so all the
    # changes then run in that one session.
    # 5.5/5.6 have no ALTER USER ... IDENTIFIED BY or CREATE USER IF NOT EXISTS; 5.7+ and MariaDB do.
    case "$(sql 'SELECT VERSION()')" in 5.5.*|5.6.*) LEGACY=true ;; *) LEGACY=false ;; esac
    ACCOUNTS=$(sql 'SELECT user, host FROM mysql.user')
    STATEMENTS="FLUSH PRIVILEGES;"
    set_password() { # <user> <host> <password>
        if $LEGACY; then STATEMENTS+=" SET PASSWORD FOR $(lit "$1")@$(lit "$2") = PASSWORD($(lit "$3"));"
        else STATEMENTS+=" ALTER USER $(lit "$1")@$(lit "$2") IDENTIFIED BY $(lit "$3");"; fi
        echo "Set the password of $1@$2"
    }
    ensure_account() { # <user> <password> <privileges ON object> [WITH GRANT OPTION]
        if grep -qxF "$1"$'\t%' <<< "$ACCOUNTS"; then
            STATEMENTS+=" GRANT $3 TO $(lit "$1")@'%' ${4:-};"
        elif $LEGACY; then
            STATEMENTS+=" GRANT $3 TO $(lit "$1")@'%' IDENTIFIED BY $(lit "$2") ${4:-};"
            echo "Created $1@%"
        else
            STATEMENTS+=" CREATE USER $(lit "$1")@'%' IDENTIFIED BY $(lit "$2"); GRANT $3 TO $(lit "$1")@'%' ${4:-};"
            echo "Created $1@%"
        fi
    }
    OTHERS=()
    # Split by hand: `read` with IFS=tab would drop an anonymous account's empty user name (tab is
    # IFS whitespace, so a leading one is skipped).
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        user=${line%%$'\t'*} host=${line#*$'\t'}
        case "$user" in
            '') STATEMENTS+=" DROP USER ''@$(lit "$host");"; echo "Removed anonymous account ''@$host" ;;
            root) set_password root "$host" "$MYSQL_ROOT_PASSWORD" ;;
            "$DB_USER") set_password "$DB_USER" "$host" "$MYSQL_PASSWORD" ;;
            mysql.sys|mysql.session|mysql.infoschema|mariadb.sys) ;;
            *) OTHERS+=("$user@$host") ;;
        esac
    done <<< "$ACCOUNTS"
    ensure_account root "$MYSQL_ROOT_PASSWORD" 'ALL PRIVILEGES ON *.*' 'WITH GRANT OPTION'
    ensure_account "$DB_USER" "$MYSQL_PASSWORD" "ALL PRIVILEGES ON \`${DB_NAME//\`/\`\`}\`.*"
    STATEMENTS+=" FLUSH PRIVILEGES;"
    # On stdin, so the passwords aren't in the client's argv.
    "$CLIENT" --socket="$SOCKET" -uroot <<< "$STATEMENTS"
    [ ${#OTHERS[@]} -eq 0 ] || echo "Kept the other accounts (remove any this instance doesn't need): ${OTHERS[*]}"
    kill "$PID" && wait "$PID" || true
    exit 0
fi

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
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done
[ -n "$VOLUME" ] || { echo "usage: $0 --volume=<db data volume or host dir> [--image=mysql:5.6] [--user=openmrs] [--database=openmrs]" >&2; exit 1; }
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD (the new root password) must be set}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD (the new password for --user) must be set}"
if [ -n "$(docker ps -q --filter "volume=$VOLUME")" ]; then
    echo "error: a running container is using $VOLUME -- stop it first (two servers on one data directory corrupt it)" >&2
    exit 1
fi
RESET_DB_USER="$DB_USER" RESET_DB_NAME="$DB_NAME" docker run --rm \
    -e MYSQL_ROOT_PASSWORD -e MYSQL_PASSWORD -e RESET_DB_USER -e RESET_DB_NAME \
    -v "$VOLUME:/var/lib/mysql" -v "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0"):/reset-mysql-accounts.sh:ro" \
    --entrypoint bash "$IMAGE" /reset-mysql-accounts.sh --in-container
