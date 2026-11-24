#!/bin/bash
# dhis2's healthcheck (compose.yaml): healthy once DHIS2 answers at /dhis/. bash's /dev/tcp, since
# the images DHIS2 may run in don't all have curl or wget.
# /dhis/, because it answers without a login (200, or a 302 to the login page) whatever version
# runs, wherever that version keeps its login page: the old dhis-web-commons/.../login.action moved
# to a login app in 2.41. test/integration/dhis2.bats checks it on 2.43. Tomcat maps /dhis/ only
# once DHIS2 has started, its migrations included, and gives 404 before then or if it failed.
# /api/system/ping isn't used: before 2.3x it needs a login.
exec 3<>/dev/tcp/127.0.0.1/8080 || exit 1
printf 'GET /dhis/ HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
read -r _ status _ <&3
case "$status" in 200|302) exit 0 ;; *) exit 1 ;; esac
