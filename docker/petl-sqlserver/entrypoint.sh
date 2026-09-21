#!/bin/bash
set -e

if [ "$1" = '/opt/mssql/bin/sqlservr' ]; then
  if [ ! -f /tmp/db-initialized ]; then
    function create_initial_database() {
      # Poll until SQL Server actually accepts connections rather than sleeping a fixed
      # interval and hoping. A fixed sleep races a cold or loaded host: if the server
      # isn't listening yet, the CREATE fails, `set -e` kills this backgrounded subshell,
      # and the container then serves happily without the database ever being created --
      # surfacing much later as an opaque JDBC error in whatever tries to use it.
      local attempts=60
      local interval=5
      local i
      for ((i = 1; i <= attempts; i++)); do
        if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -d master -Q "SELECT 1" >/dev/null 2>&1; then
          break
        fi
        if [ "$i" -eq "$attempts" ]; then
          echo "entrypoint: timed out after $((attempts * interval))s waiting for SQL Server to accept connections; ${DATABASE_NAME} was NOT created" >&2
          return 1
        fi
        sleep "$interval"
      done
      # Guarded rather than a bare CREATE DATABASE: /tmp/db-initialized doesn't live on the
      # data volume, so a restarted container reruns this against a datadir that already
      # has the database.
      /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -d master \
        -Q "IF DB_ID('${DATABASE_NAME}') IS NULL CREATE DATABASE [${DATABASE_NAME}]"
      touch /tmp/db-initialized
      echo "entrypoint: database ${DATABASE_NAME} is ready"
    }
    create_initial_database &
  fi
fi

exec "$@"
