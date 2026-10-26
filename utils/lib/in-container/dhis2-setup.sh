#!/bin/sh
# Runs before every start of dhis2 (dhis2.yaml's dhis2-setup): writes dhis.conf into the DHIS2 home
# from the DHIS2_* variables in its environment. Values reach it only through its environment, never
# its command line.
set -eu
HOME_DIR=${DHIS2_HOME:?DHIS2_HOME must be set}

# dhis.conf is a Java properties file: a backslash would start an escape, so it's doubled.
prop() { # <key> <value>
    printf '%s = %s\n' "$1" "$(printf '%s' "$2" | sed 's/\\/\\\\/g')"
}

conf="$HOME_DIR/.dhis.conf.new"
umask 077
{
    echo "# Written by distro-tools' dhis2-setup on every start, from the instance's env file."
    prop connection.dialect org.hibernate.dialect.PostgreSQLDialect
    prop connection.driver_class org.postgresql.Driver
    prop connection.url "jdbc:postgresql://dhis2-db/${DHIS2_DB_NAME:?DHIS2_DB_NAME must be set}"
    prop connection.username "${DHIS2_DB_USER:?DHIS2_DB_USER must be set}"
    prop connection.password "${DHIS2_DB_PASSWORD:?DHIS2_DB_PASSWORD must be set}"
    prop server.base.url "${DHIS2_BASE_URL:?DHIS2_BASE_URL must be set}"
    [ -z "${DHIS2_ENCRYPTION_PASSWORD:-}" ] || prop encryption.password "$DHIS2_ENCRYPTION_PASSWORD"
    # DHIS2_CONF_<key>: '_' in <key> is '.', and '__' is '_' (as OMRS_EXTRA_* runtime properties).
    for var in $(env | sed -n 's/^\(DHIS2_CONF_[A-Za-z0-9_]*\)=.*/\1/p'); do
        key=$(printf '%s' "${var#DHIS2_CONF_}" | sed 's/__/%/g; s/_/./g; s/%/_/g')
        prop "$key" "$(printenv "$var")"
    done
} > "$conf"
mv "$conf" "$HOME_DIR/dhis.conf"
echo "Wrote $HOME_DIR/dhis.conf."
