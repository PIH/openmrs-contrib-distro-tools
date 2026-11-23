#!/bin/sh
# dhis2-setup (compose.yaml), before every start of dhis2, in the same Tomcat image: checks
# DHIS2_VERSION and DHIS2_TOMCAT_TAG against the versions list, refuses a downgrade, makes sure the
# version's release WAR is in DHIS2_WARS and verified, and writes dhis.conf and the version marker
# into DHIS2_HOME. Values reach it only through its environment, never its command line, and it
# never prints one that could be a secret.
set -eu
VERSION=${DHIS2_VERSION:?DHIS2_VERSION must be set}
VERSIONS_FILE=${DHIS2_VERSIONS_FILE:-/versions}
HOME_DIR=${DHIS2_HOME:?DHIS2_HOME must be set}
WARS=${DHIS2_WARS:-/wars}
MARKER="$HOME_DIR/.dhis2-version"

die() { echo "error: $*" >&2; exit 1; }

# The position of <version> in the list (1 is the oldest), or nothing.
position() { # <version>
    awk -v v="$1" '/^#/ || NF == 0 { next } { n++ } $1 == v { print n; exit }' "$VERSIONS_FILE"
}

# 1. The version's Tomcat tag, WAR URL and checksum.
entry=$(awk -v v="$VERSION" '!/^#/ && $1 == v { print $2, $3, $4; exit }' "$VERSIONS_FILE")
[ -n "$entry" ] || die "DHIS2_VERSION '$VERSION' isn't in services/dhis2/scripts/versions"
# shellcheck disable=SC2086 # three words
set -- $entry
TAG=$1 URL=$2 SHA256=$3

# 2. This container runs in tomcat:DHIS2_TOMCAT_TAG, as dhis2 does: it must be the version's.
[ "${DHIS2_TOMCAT_TAG:-}" = "$TAG" ] ||
    die "DHIS2 $VERSION runs on tomcat:$TAG; DHIS2_TOMCAT_TAG is ${DHIS2_TOMCAT_TAG:-}. Set DHIS2_TOMCAT_TAG=$TAG."

# 3. DHIS2's database migrations can't be undone: an older version than the last one started would
# run on a schema it doesn't know.
if [ -f "$MARKER" ]; then
    last=$(cat "$MARKER")
    last_position=$(position "$last")
    [ -n "$last_position" ] ||
        die "this instance last ran DHIS2 $last ($MARKER), which isn't in services/dhis2/scripts/versions, so it can't tell whether $VERSION is a downgrade."
    [ "$last_position" -le "$(position "$VERSION")" ] ||
        die "this instance last ran DHIS2 $last; DHIS2_VERSION is $VERSION. DHIS2 can't be downgraded: set DHIS2_VERSION to $last or later."
fi

# 4. The WAR, downloaded only when it isn't there already, verified.
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
war="$WARS/dhis2-$VERSION.war"
part="$war.part"
if [ -f "$war" ] && [ "$(sha256_of "$war")" = "$SHA256" ]; then
    echo "DHIS2 $VERSION's WAR is there and verified."
else
    rm -f "$war"
    trap 'rm -f "$part"' EXIT
    echo "Downloading DHIS2 $VERSION from $URL..."
    curl -fsSL --retry 3 -o "$part" "$URL" || die "couldn't download $URL"
    actual=$(sha256_of "$part")
    [ "$actual" = "$SHA256" ] ||
        die "the download from $URL has SHA-256 $actual, not $SHA256 (services/dhis2/scripts/versions): deleted it"
    mv "$part" "$war"
    echo "Downloaded and verified DHIS2 $VERSION's WAR."
fi

# 5. dhis.conf, a Java properties file: a backslash would start an escape, so it's doubled.
prop() { # <key> <value>
    printf '%s = %s\n' "$1" "$(printf '%s' "$2" | sed 's/\\/\\\\/g')"
}
conf="$HOME_DIR/.dhis.conf.new"
(
    umask 077
    {
        echo "# Written by dhis2-setup on every start, from the instance's dhis2 settings."
        prop connection.dialect org.hibernate.dialect.PostgreSQLDialect
        prop connection.driver_class org.postgresql.Driver
        prop connection.url "jdbc:postgresql://dhis2-db/${DHIS2_DB_NAME:?DHIS2_DB_NAME must be set}"
        prop connection.username "${DHIS2_DB_USER:?DHIS2_DB_USER must be set}"
        prop connection.password "${DHIS2_DB_PASSWORD:?DHIS2_DB_PASSWORD must be set}"
        # Without it, 2.30 falls back to its test default, create-drop, and empties the database.
        prop connection.schema update
        prop server.base.url "${DHIS2_BASE_URL:?DHIS2_BASE_URL must be set}"
        [ -z "${DHIS2_ENCRYPTION_PASSWORD:-}" ] || prop encryption.password "$DHIS2_ENCRYPTION_PASSWORD"
        # DHIS2_CONF_<key>: '_' in <key> is '.', and '__' is '_'. Only the names are read from env;
        # the values come from printenv straight into the file.
        for var in $(env | sed -n 's/^\(DHIS2_CONF_[A-Za-z0-9_]*\)=.*/\1/p'); do
            key=$(printf '%s' "${var#DHIS2_CONF_}" | sed 's/__/%/g; s/_/./g; s/%/_/g')
            prop "$key" "$(printenv "$var")"
        done
    } > "$conf"
)
mv "$conf" "$HOME_DIR/dhis.conf"
echo "Wrote $HOME_DIR/dhis.conf."

# 6. What the downgrade check reads next time. Written before DHIS2 starts: once it has started on
# this version, its migrations may have run.
echo "$VERSION" > "$MARKER"
