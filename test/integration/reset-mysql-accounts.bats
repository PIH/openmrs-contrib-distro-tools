#!/usr/bin/env bats
# reset-mysql-accounts sets a stopped data directory's accounts to new passwords; openmrs-docker
# reset-openmrs-db-accounts uses it, and also updates OpenMRS's connection settings, to rotate passwords.

load ../helpers

setup() { cd "$BATS_TEST_TMPDIR"; }
teardown() {
    [ -n "${NAME:-}" ] && destroy_instance "$NAME"
    common_teardown
}

in_volume() { # <volume> <sh command>
    docker run --rm -v "$1:/data" alpine:3.21 sh -c "$2"
}

@test "reset-openmrs-db-accounts sets the MySQL accounts and OpenMRS's connection settings to the passwords now in env" {
    NAME="$(instance)"
    local dir env
    SERVICES=openmrs-db create_instance "$NAME"
    dir="$OPENMRS_DOCKER_HOME/$NAME"
    echo 'CREATE TABLE marker (id INT); INSERT INTO marker VALUES (1);' > dump.sql
    run_initialize "$NAME" RESTORE_MYSQL_DUMP_PATH=dump.sql
    assert_success
    # openmrs-data as OpenMRS leaves it after its first start
    docker volume create "${NAME}_openmrs-data" >/dev/null
    in_volume "${NAME}_openmrs-data" '
        printf "connection.url=jdbc\\\\:mysql\\\\://openmrs-db\\\\:3306/openmrs\nconnection.username=openmrs\nconnection.password=openmrs\nmail.smtp.host=smtp.example.org\n" > /data/openmrs-runtime.properties
        chown 1001:0 /data/openmrs-runtime.properties && chmod 640 /data/openmrs-runtime.properties'
    "$BIN/openmrs-docker" "$NAME" start >/dev/null 2>&1

    sed -i "s/^OPENMRS_DB_PASSWORD=.*/OPENMRS_DB_PASSWORD='n3w\\\\pw'/; s/^OPENMRS_DB_ROOT_PASSWORD=.*/OPENMRS_DB_ROOT_PASSWORD='n3w-root'/" "$dir/env"
    run grep '^OPENMRS_DB_PASSWORD=' "$dir/env"
    assert_output "OPENMRS_DB_PASSWORD='n3w\\pw'"
    run "$BIN/openmrs-docker" "$NAME" reset-openmrs-db-accounts
    assert_success
    assert_output --partial "Set the password of root@localhost"
    assert_output --partial "Set connection.username and connection.password"

    wait_for_mysql "$NAME-openmrs-db" root n3w-root
    run mysql_exec "$NAME-openmrs-db" openmrs 'SELECT 1'
    assert_failure
    run docker exec "$NAME-openmrs-db" sh -c 'mysql -h127.0.0.1 -uopenmrs "-pn3w\\pw" -N -e "SELECT id FROM openmrs.marker" 2>/dev/null'
    assert_output 1
    # the properties format doubles a backslash; everything else in the file, and its owner and mode, stay
    run in_volume "${NAME}_openmrs-data" 'grep -c "^connection.password=" /data/openmrs-runtime.properties; cat /data/openmrs-runtime.properties; stat -c "%u:%g %a" /data/openmrs-runtime.properties; grep -c "^connection.password=openmrs$" /data/openmrs-runtime.properties.bak'
    assert_line --index 0 1
    assert_line 'connection.password=n3w\\pw'
    assert_line 'connection.url=jdbc\:mysql\://openmrs-db\:3306/openmrs'
    assert_line 'mail.smtp.host=smtp.example.org'
    assert_line '1001:0 640'
    assert_line --index -1 1
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
