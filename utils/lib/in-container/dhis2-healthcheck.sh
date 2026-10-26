#!/bin/bash
# dhis2.yaml's healthcheck: healthy once DHIS2's login page answers. bash's /dev/tcp, since the images
# DHIS2 may run in don't all have curl or wget. /api/system/ping isn't used: before 2.3x it needs a
# login.
exec 3<>/dev/tcp/127.0.0.1/8080 || exit 1
printf 'GET /dhis/dhis-web-commons/security/login.action HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
read -r _ status _ <&3
case "$status" in 200|302) exit 0 ;; *) exit 1 ;; esac
