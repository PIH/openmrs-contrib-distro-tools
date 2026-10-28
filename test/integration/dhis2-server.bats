#!/usr/bin/env bats
# dhis2-server.xml, the Tomcat config the dhis2 fragment mounts: behind a TLS-terminating proxy (Caddy)
# that forwards plain HTTP, Tomcat takes the scheme from X-Forwarded-Proto. Against the stock Tomcat
# image with a one-page webapp that prints what the request looks like to the application.

load ../helpers

TOMCAT_IMAGE=tomcat:9-jdk17

setup() {
    C="$(res tomcat)"
    mkdir -p "$BATS_TEST_TMPDIR/probe"
    echo '<%= request.getScheme() %> <%= request.isSecure() %> <%= request.getServerPort() %> <%= request.getRemoteAddr() %>' \
        > "$BATS_TEST_TMPDIR/probe/index.jsp"
    docker run -d --name "$C" \
        -v "$UTILS/lib/in-container/dhis2-server.xml:/usr/local/tomcat/conf/server.xml:ro" \
        -v "$BATS_TEST_TMPDIR/probe:/usr/local/tomcat/webapps/probe:ro" \
        "$TOMCAT_IMAGE" >/dev/null
    local i
    for i in $(seq 60); do
        docker exec "$C" curl -fs -o /dev/null http://127.0.0.1:8080/probe/ && return 0
        sleep 1
    done
    docker logs "$C" >&2
    fail "Tomcat didn't serve the probe page"
}
teardown() { common_teardown; }

probe() { docker exec "$C" curl -fs "$@" http://127.0.0.1:8080/probe/; }

@test "a request the proxy received over HTTPS is HTTPS to DHIS2" {
    run probe -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.7'
    assert_success
    assert_output --regexp '^https true 443 203\.0\.113\.7'
}

@test "a request without the header stays HTTP" {
    run probe
    assert_success
    assert_output --regexp '^http false 8080 127\.0\.0\.1'
}
