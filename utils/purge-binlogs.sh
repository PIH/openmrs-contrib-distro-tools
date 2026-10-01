#!/bin/bash
# Has a MySQL/MariaDB server delete its binary logs except the current one (PURGE BINARY LOGS).
# Run it before turning binary logging off: the server can't purge them afterwards.
#
# Usage: openmrs-utils purge-binlogs (--container=<name> | --host=<host> [--port=3306]
#            [--client-image=mysql:5.6]) [--user=root]
#   MYSQL_PASSWORD  password for --user, who needs SUPER or BINLOG_ADMIN (required)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/mysql.sh
. "$UTILS_DIR/lib/mysql.sh"

for arg in "$@"; do
    case "$arg" in
        --user=*) DB_USER="${arg#*=}" ;;
        --client-image=*) DB_CLIENT_IMAGE="${arg#*=}" ;;
        *) mysql_source_arg "$arg" || die "unknown argument: $arg" ;;
    esac
done
mysql_source_given || usage
mysql_password
mysql_connect "$DB_PASSWORD"

[ "$(sql 'SELECT @@log_bin')" = 1 ] || die "binary logging is off on $MYSQL_SOURCE, so it can't purge its binlogs. Turn it back on (e.g. OPENMRS_DB_OPT_log_bin=mysql-bin), restart, then run this again."
summary() { sql 'SHOW BINARY LOGS' | awk '{ n++; b += $2 } END { printf "%d file(s), %d bytes", n, b }'; }

note "Binary logs on $MYSQL_SOURCE before: $(summary)"
sql 'FLUSH BINARY LOGS'
# The newest file listed is the current one (SHOW MASTER STATUS is gone in MySQL 8.4). MariaDB
# keeps a binlog until InnoDB has checkpointed past it, which lags the FLUSH briefly.
for _ in $(seq 30); do
    sql "PURGE BINARY LOGS TO '$(sql 'SHOW BINARY LOGS' | awk 'END { print $1 }')'"
    [ "$(sql 'SHOW BINARY LOGS' | wc -l)" -gt 1 ] || break
    sleep 1
done
note "Binary logs on $MYSQL_SOURCE after:  $(summary)"
