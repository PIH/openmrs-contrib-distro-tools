# Shared helpers for the bats test suite. Load from a test file with `load ../helpers`.
# Variables defined here are used by the test files that load it.
# shellcheck disable=SC2034

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
BIN="$REPO_ROOT/bin"
UTILS="$REPO_ROOT/utils"
MYSQL_IMAGE=mysql:5.6

bats_require_minimum_version 1.5.0

load "$TEST_DIR/.deps/bats-support/load"
load "$TEST_DIR/.deps/bats-assert/load"

# Every Docker container/volume a test creates is named under RUN_PREFIX, so teardown can find and
# remove exactly this run's resources (and assert_no_leftovers can check for them) without touching
# anything else on the machine. Lowercase + digits only: valid as a Compose project name.
export RUN_PREFIX="${RUN_PREFIX:-odt${BATS_ROOT_PID}}"

# openmrs-docker instances live in a throwaway home, use a placeholder OpenMRS image (initialize
# only ever starts openmrs-db) and random host ports, so tests never collide with a real instance.
export OPENMRS_DOCKER_HOME="$BATS_RUN_TMPDIR/openmrs-home"
export OPENMRS_IMAGE_NAME=placeholder/openmrs
export OPENMRS_DB_PORT=0
export OPENMRS_HTTP_PORT=0
export OPENMRS_DB_INNODB_BUFFER_POOL_SIZE=256M
# initialize would otherwise run the (placeholder) OpenMRS image to find the owner for a restored
# openmrs-data. The test runner's own ids keep restored fixtures readable by the tests.
OPENMRS_DATA_OWNER="$(id -u):$(id -g)"
export OPENMRS_DATA_OWNER

# A name for a Docker resource owned by the current test, e.g. `res db` -> odt1234-t7-db.
res() { echo "$RUN_PREFIX-t${BATS_TEST_NUMBER}-$1"; }

# A name for an openmrs-docker instance owned by the current test.
instance() { echo "$RUN_PREFIX-t${BATS_TEST_NUMBER}${1:+-$1}"; }

remove_resources() { # <name prefix>
    local ids
    ids=$(docker ps -aq --filter "name=^$1")
    [ -n "$ids" ] && docker rm -f $ids >/dev/null
    ids=$(docker volume ls -q --filter "name=^$1")
    [ -n "$ids" ] && docker volume rm -f $ids >/dev/null
    ids=$(docker network ls -q --filter "name=^$1")
    [ -n "$ids" ] && docker network rm $ids >/dev/null
    return 0
}

# Fails if any container, volume or network under <prefix> still exists.
assert_no_leftovers() { # [prefix, default: the current test's]
    local prefix="${1:-$RUN_PREFIX-t${BATS_TEST_NUMBER}}" left
    left=$( { docker ps -a --format '{{.Names}}' --filter "name=^$prefix";
              docker volume ls -q --filter "name=^$prefix";
              docker network ls --format '{{.Name}}' --filter "name=^$prefix"; } )
    [ -z "$left" ] || fail "leftover Docker resources: $left"
}

# Some scripts leave root-owned files behind (written from inside containers); hand them back so
# bats can delete its temp dirs.
reclaim() { # <dir>
    [ -d "$1" ] && docker run --rm -v "$1:/t" alpine:3.21 chown -R "$(id -u):$(id -g)" /t >/dev/null 2>&1
    return 0
}

common_teardown() {
    remove_resources "$RUN_PREFIX-t${BATS_TEST_NUMBER}"
    reclaim "$BATS_TEST_TMPDIR"
}

common_teardown_file() {
    remove_resources "$RUN_PREFIX-f"
    reclaim "$BATS_FILE_TMPDIR"
}

# --- MySQL -----------------------------------------------------------------------------------------

# Waits until <container> accepts a TCP login (not just the socket, which also answers during the
# image's temporary first-boot server).
wait_for_mysql() { # <container> <user> <password> [timeout seconds]
    local deadline=$(( $(date +%s) + ${4:-120} ))
    until docker exec "$1" mysql -h127.0.0.1 "-u$2" "-p$3" -e 'SELECT 1' >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || { docker logs --tail 30 "$1" >&2; return 1; }
        sleep 2
    done
}

mysql_exec() { # <container> <root password> <sql>
    docker exec "$1" mysql -h127.0.0.1 -uroot "-p$2" -N -e "$3" 2>/dev/null
}

# Starts a MySQL container with a named data volume (<name>-data) holding an `openmrs` database
# (marker row 1) and a `malawi` database (marker row 2). Credentials match openmrs-docker's
# defaults, so a physical restore of it is usable by an instance created with those defaults.
start_source_db() { # <name>
    docker run -d --name "$1" -v "$1-data:/var/lib/mysql" \
        -e MYSQL_ROOT_PASSWORD=openmrs -e MYSQL_DATABASE=openmrs \
        -e MYSQL_USER=openmrs -e MYSQL_PASSWORD=openmrs \
        "$MYSQL_IMAGE" --log-bin=mysql-bin --server-id=1 >/dev/null
    wait_for_mysql "$1" root openmrs
    mysql_exec "$1" openmrs "
        CREATE TABLE openmrs.marker (id INT) ENGINE=InnoDB; INSERT INTO openmrs.marker VALUES (1);
        CREATE DATABASE malawi;
        CREATE TABLE malawi.marker (id INT) ENGINE=InnoDB; INSERT INTO malawi.marker VALUES (2);"
}

# Runs <sql> against the `openmrs` database of a restored MySQL data volume and prints the result, by
# starting a throwaway MySQL on it and logging in with the instance's default credentials. Prints
# nothing if it can't log in.
db_query_in_volume() { # <volume> <sql>
    local c
    c="$(res verify-db)"
    docker run -d --name "$c" -v "$1:/var/lib/mysql" "$MYSQL_IMAGE" >/dev/null
    if wait_for_mysql "$c" openmrs openmrs 90; then
        docker exec "$c" mysql -h127.0.0.1 -uopenmrs -popenmrs -N openmrs -e "$2" 2>&1 | grep -v 'Using a password' || true
    fi
    docker rm -f "$c" >/dev/null
}

db_marker_in_volume() { # <volume>
    db_query_in_volume "$1" 'SELECT id FROM marker'
}

# --- openmrs-docker --------------------------------------------------------------------------------

create_instance() { # <name>
    "$BIN/openmrs-docker" create "$1" >/dev/null
}

# Runs `openmrs-docker <name> initialize` via bats `run`, with extra env assignments, capped so a
# hung restore fails the test instead of waiting out initialize's own hour-long wait.
run_initialize() { # <name> [VAR=value...]
    local name=$1; shift
    run env "$@" timeout 300 "$BIN/openmrs-docker" "$name" initialize
}

destroy_instance() { # <name>
    "$BIN/openmrs-docker" "$1" destroy --force >/dev/null 2>&1 || true
}

# A tiny, valid logical dump (plain SQL), for tests that need initialize to have a db source but
# aren't testing the database itself.
write_tiny_dump() { # <path>
    printf 'CREATE TABLE marker (id INT);\nINSERT INTO marker VALUES (1);\n' > "$1"
}

# --- openmrs-data fixtures -------------------------------------------------------------------------

# Builds a data directory covering every case the backup/restore scripts treat specially: a dotfile,
# nested dirs, real state (runtime properties, complex_obs), and the four distribution-artifact dirs
# that --exclude-distribution-artifacts empties.
make_data_fixture() { # <dir>
    mkdir -p "$1"/{modules,owa,configuration/addresshierarchy,frontend,complex_obs,.hidden,.openmrs-lib-cache}
    echo 'connection.url=jdbc:mysql://x/openmrs' > "$1/openmrs-runtime.properties"
    echo omod > "$1/modules/a.omod"
    echo owa > "$1/owa/app.zip"
    echo csv > "$1/configuration/addresshierarchy/h.csv"
    echo js > "$1/frontend/f.js"
    echo img > "$1/complex_obs/1.jpg"
    echo h > "$1/.hidden/h"
    echo cls > "$1/.openmrs-lib-cache/c.class"
}

# The full fixture tree, written out by hand (not computed from make_data_fixture).
FIXTURE_TREE="./.hidden
./.hidden/h
./.openmrs-lib-cache
./.openmrs-lib-cache/c.class
./complex_obs
./complex_obs/1.jpg
./configuration
./configuration/addresshierarchy
./configuration/addresshierarchy/h.csv
./frontend
./frontend/f.js
./modules
./modules/a.omod
./openmrs-runtime.properties
./owa
./owa/app.zip"

# The fixture tree after --exclude-distribution-artifacts: those four dirs kept, but empty, and
# .openmrs-lib-cache left out.
FIXTURE_TREE_EXCLUDED="./.hidden
./.hidden/h
./complex_obs
./complex_obs/1.jpg
./configuration
./frontend
./modules
./openmrs-runtime.properties
./owa"

tree_of() { # <dir>
    (cd "$1" && find . -mindepth 1 | LC_ALL=C sort)
}

tree_of_volume() { # <volume>
    docker run --rm -v "$1:/d:ro" alpine:3.21 sh -c 'cd /d && find . -mindepth 1 | LC_ALL=C sort'
}

# --- docker argv capture ---------------------------------------------------------------------------

# Puts a `docker` wrapper first on PATH that records every docker command line to $DOCKER_ARGV_LOG,
# then runs the real docker unchanged -- so a test can assert that no secret ever appears in a
# command line (and so in `ps`).
record_docker_argv() {
    local real shim_dir="$BATS_TEST_TMPDIR/docker-shim"
    real="$(command -v docker)"
    mkdir -p "$shim_dir"
    export DOCKER_ARGV_LOG="$BATS_TEST_TMPDIR/docker-argv.log"
    : > "$DOCKER_ARGV_LOG"
    cat > "$shim_dir/docker" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$DOCKER_ARGV_LOG"
exec "$real" "\$@"
EOF
    chmod +x "$shim_dir/docker"
    export PATH="$shim_dir:$PATH"
}

assert_not_in_docker_argv() { # <secret>
    [ -s "$DOCKER_ARGV_LOG" ] || fail "no docker commands were recorded"
    if grep -qF -- "$1" "$DOCKER_ARGV_LOG"; then
        fail "secret appeared in a docker command line: $(grep -F -- "$1" "$DOCKER_ARGV_LOG")"
    fi
}
