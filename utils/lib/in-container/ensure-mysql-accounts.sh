#!/bin/bash
# Runs inside openmrs-db's image as openmrs-db-accounts (openmrs-db.yaml), once openmrs-db is
# healthy. For each account declared in the environment as
#   OPENMRS_DB_ACCOUNT_<ID>_USER       user name (account <user>@'%')
#   OPENMRS_DB_ACCOUNT_<ID>_PASSWORD   password, set on every run (so a rotated one, or a restored
#                                      data directory's old one, is replaced)
#   OPENMRS_DB_ACCOUNT_<ID>_GRANTS     <privileges> ON <db>.<table>[;<privileges> ON <db>.<table>...]
#   OPENMRS_DB_ACCOUNT_<ID>_DATABASES  optional, space-separated databases, created if missing
# it creates the account if missing, sets its password, creates the databases and applies the
# grants. Everything is checked first: a bad declaration changes nothing. Accounts not declared,
# and other hosts' accounts for the same user, are left alone.
# root and the OpenMRS account (OPENMRS_DB_USER) can't be declared: their passwords are the instance's
# own (OPENMRS_DB_*), set by the image and reset-openmrs-db-accounts.
#   MYSQL_ROOT_PASSWORD  root's password (required); OPENMRS_DB_USER (default openmrs);
#   DB_HOST default openmrs-db
set -euo pipefail
source /mysql-accounts.sh

: "${MYSQL_ROOT_PASSWORD:?}"
CLIENT=mysql; command -v mysql >/dev/null || CLIENT=mariadb
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"   # not on the command line
HOST=${DB_HOST:-openmrs-db}
sql() { "$CLIENT" -h "$HOST" -uroot -N -B -e "$1"; }
trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

ids=$(compgen -v | sed -n 's/^OPENMRS_DB_ACCOUNT_\(.*\)_\(USER\|PASSWORD\|GRANTS\|DATABASES\)$/\1/p' | sort -u)
if [ -z "$ids" ]; then echo "No OPENMRS_DB_ACCOUNT_* accounts declared"; exit 0; fi

ident='^[A-Za-z0-9_]+$'
grant='^[A-Za-z][A-Za-z ,]* ON (\*|[A-Za-z0-9_]+)\.(\*|[A-Za-z0-9_]+)$'
errors=()
for id in $ids; do
    p="OPENMRS_DB_ACCOUNT_${id}"
    u="${p}_USER" pw="${p}_PASSWORD" g="${p}_GRANTS" d="${p}_DATABASES"
    [[ "$id" =~ $ident ]] || errors+=("$p: the id must be letters, digits and _")
    [[ "${!u:-}" =~ $ident ]] || errors+=("$u must be set, to letters, digits and _")
    case "${!u:-}" in
        root|"${OPENMRS_DB_USER:-openmrs}")
            errors+=("$u can't be ${!u}: that account's password is the instance's own (OPENMRS_DB_*). Use an account of its own (for PETL, PETL_MYSQL_USER='petl')") ;;
    esac
    [ -n "${!pw:-}" ] || errors+=("$pw must be set")
    [[ "${!pw:-}" != *\\* ]] || errors+=("$pw can't contain a backslash")
    [ -n "${!g:-}" ] || errors+=("$g must be set")
    IFS=';' read -ra list <<< "${!g:-}"
    for x in "${list[@]}"; do
        [[ "$(trim "$x")" =~ $grant ]] || errors+=("$g: '$(trim "$x")' isn't <privileges> ON <db>.<table>")
    done
    for db in ${!d:-}; do [[ "$db" =~ $ident ]] || errors+=("$d: '$db' isn't a plain database name"); done
done
if [ ${#errors[@]} -gt 0 ]; then
    printf 'error: %s\n' "${errors[@]}" "nothing was changed" >&2
    exit 1
fi

if mysql_is_legacy "$(sql 'SELECT VERSION()')"; then legacy=true; else legacy=false; fi
existing=$(sql "SELECT user FROM mysql.user WHERE host = '%'")
statements=""
for id in $ids; do
    p="OPENMRS_DB_ACCOUNT_${id}"
    u="${p}_USER" pw="${p}_PASSWORD" g="${p}_GRANTS" d="${p}_DATABASES"
    for db in ${!d:-}; do
        statements+=" CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8;"
        echo "Database $db ready"
    done
    if grep -qxF "${!u}" <<< "$existing"; then
        statements+=" $(sql_set_password "${!u}" % "${!pw}" "$legacy")"
        echo "Set the password of ${!u}@%"
    else
        statements+=" $(sql_create_user "${!u}" "${!pw}" "$legacy")"
        echo "Created ${!u}@%"
    fi
    IFS=';' read -ra list <<< "${!g}"
    for x in "${list[@]}"; do statements+=" GRANT $(trim "$x") TO $(lit "${!u}")@'%';"; done
done
statements+=" FLUSH PRIVILEGES;"
"$CLIENT" -h "$HOST" -uroot <<< "$statements"   # on stdin: passwords stay off argv
