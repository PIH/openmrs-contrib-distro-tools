#!/usr/bin/env bats
# reset-mysql-accounts sets a stopped data directory's accounts to new passwords; openmrs-db
# reset-accounts uses it, and also updates OpenMRS's connection settings, to rotate passwords.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && remove_test_instance "$NAME"
    common_teardown
}

in_volume() { # <volume> <sh command>
    docker run --rm -v "$1:/data" alpine:3.21 sh -c "$2"
}

@test "openmrs-db reset-accounts sets the MySQL accounts to the passwords now in openmrs-db.env, and leaves OpenMRS's runtime properties alone" {
    NAME="$(instance)"
    local env
    create_instance "$NAME" --services=openmrs-db
    env="$(env_file_of "$NAME" openmrs-db)"
    echo 'CREATE TABLE marker (id INT); INSERT INTO marker VALUES (1);' > dump.sql
    run_initialize "$NAME" --from "$(from_folder openmrs-db.sql dump.sql)"
    assert_success
    # openmrs-data as OpenMRS leaves it after its first start: OpenMRS takes the new connection
    # settings from env on its next start (openmrs-core 2.8.11+), so the file is left alone
    docker volume create "${NAME}_openmrs-data" >/dev/null
    in_volume "${NAME}_openmrs-data" '
        printf "connection.username=openmrs\nconnection.password=openmrs\n" > /data/openmrs-runtime.properties'
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1

    set_env_value "$NAME" openmrs-db OPENMRS_DB_PASSWORD 'n3w\pw'
    set_env_value "$NAME" openmrs-db OPENMRS_DB_ROOT_PASSWORD n3w-root
    run grep '^OPENMRS_DB_PASSWORD=' "$env"
    assert_output "OPENMRS_DB_PASSWORD='n3w\\pw'"
    run "$BIN/openmrs-docker" "$NAME" openmrs-db reset-accounts
    assert_success
    assert_output --partial "Set the password of root@localhost"

    wait_for_mysql "$NAME-openmrs-db" root n3w-root
    run mysql_exec "$NAME-openmrs-db" openmrs 'SELECT 1'
    assert_failure
    run docker exec "$NAME-openmrs-db" sh -c 'mysql -h127.0.0.1 -uopenmrs "-pn3w\\pw" -N -e "SELECT id FROM openmrs.marker" 2>/dev/null'
    assert_output 1
    run in_volume "${NAME}_openmrs-data" 'cat /data/openmrs-runtime.properties; ls /data'
    assert_output "$(printf 'connection.username=openmrs\nconnection.password=openmrs\nopenmrs-runtime.properties')"
}

@test "reset-mysql-accounts also works on a MySQL 8 data directory" {
    local db vol
    db=$(res m8) vol=$(res m8data)
    docker run -d --name "$db" -v "$vol:/var/lib/mysql" -e MYSQL_ROOT_PASSWORD=old -e MYSQL_DATABASE=openmrs \
        -e MYSQL_USER=openmrs -e MYSQL_PASSWORD=old mysql:8.0 >/dev/null
    wait_for_mysql "$db" root old 180
    mysql_exec "$db" old "CREATE USER 'openmrs'@'localhost' IDENTIFIED BY 'legacy'; CREATE USER ''@'localhost';"
    docker rm -f "$db" >/dev/null
    MYSQL_ROOT_PASSWORD=new-root MYSQL_PASSWORD=new-pw run "$UTILS/reset-mysql-accounts.sh" --volume="$vol" --image=mysql:8.0
    assert_success
    assert_output --partial "Set the password of openmrs@localhost"
    assert_output --partial "Removed anonymous account ''@localhost"
    docker run -d --name "$db" -v "$vol:/var/lib/mysql" mysql:8.0 >/dev/null
    wait_for_mysql "$db" root new-root 180
    run docker exec "$db" sh -c 'mysql -h127.0.0.1 -uopenmrs -pnew-pw -N -e "SELECT 1" 2>/dev/null'
    assert_output 1
}

@test "reset-mysql-accounts leaves accounts with a host name alone, which the server ignores, and lists them" {
    # As on a legacy server: root@<its own host name>. MySQL images run with skip-name-resolve, so
    # the server never loads that account, and SET PASSWORD for it fails.
    local db vol
    db=$(res legacy) vol=$(res legacydata)
    docker run -d --name "$db" -v "$vol:/var/lib/mysql" -e MYSQL_ROOT_PASSWORD=old "$MYSQL_IMAGE" >/dev/null
    wait_for_mysql "$db" root old
    mysql_exec "$db" old "CREATE USER 'openmrs'@'localhost' IDENTIFIED BY 'legacy';
        INSERT INTO mysql.user (Host, User, Password, ssl_cipher, x509_issuer, x509_subject, authentication_string)
        VALUES ('ci.pih-emr.org', 'root', PASSWORD('old'), '', '', '', ''), ('%.example.org', 'petl', PASSWORD('old'), '', '', '', '');"
    docker rm -f "$db" >/dev/null
    MYSQL_ROOT_PASSWORD=new-root MYSQL_PASSWORD=new-pw run "$UTILS/reset-mysql-accounts.sh" --volume="$vol"
    assert_success
    assert_output --partial "Set the password of openmrs@localhost"
    refute_output --partial "Set the password of root@ci.pih-emr.org"
    assert_output --regexp "Left alone, since the server doesn't resolve host names \(no login can use them\): .*root@ci\.pih-emr\.org"
    assert_output --regexp "Left alone, .*petl@%\.example\.org"
    docker run -d --name "$db" -v "$vol:/var/lib/mysql" "$MYSQL_IMAGE" >/dev/null
    wait_for_mysql "$db" root new-root
    run docker exec "$db" sh -c 'mysql -h127.0.0.1 -uopenmrs -pnew-pw -N -e "SELECT 1" 2>/dev/null'
    assert_output 1
}

@test "reset-mysql-accounts refuses while a container is using the data directory, and needs both passwords" {
    local vol
    vol=$(res busy)
    docker run -d --name "$(res c)" -v "$vol:/var/lib/mysql" alpine:3.21 sleep 300 >/dev/null
    MYSQL_ROOT_PASSWORD=x MYSQL_PASSWORD=y run "$UTILS/reset-mysql-accounts.sh" --volume="$vol"
    assert_failure
    assert_output --partial "$vol is in use by a running container"
    MYSQL_ROOT_PASSWORD=x run "$UTILS/reset-mysql-accounts.sh" --volume="$vol"
    assert_failure
    assert_output --partial "MYSQL_PASSWORD"
}
