# SQL for MySQL/MariaDB accounts, shared by reset-mysql-accounts.sh and ensure-mysql-accounts.sh.
# Sourced inside a MySQL/MariaDB image. Each sql_* function prints a statement.
# shellcheck shell=bash

lit() { local v=${1//\\/\\\\}; printf "'%s'" "${v//\'/\\\'}"; }   # a quoted SQL string literal

# 5.5/5.6 have no ALTER USER ... IDENTIFIED BY or CREATE USER IF NOT EXISTS; 5.7+ and MariaDB do.
mysql_is_legacy() { case "$1" in 5.5.*|5.6.*) return 0 ;; *) return 1 ;; esac; } # <SELECT VERSION()>

sql_set_password() { # <user> <host> <password> <legacy: true|false>
    if $4; then echo "SET PASSWORD FOR $(lit "$1")@$(lit "$2") = PASSWORD($(lit "$3"));"
    else echo "ALTER USER $(lit "$1")@$(lit "$2") IDENTIFIED BY $(lit "$3");"; fi
}

sql_create_user() { # <user> <password> <legacy>: <user>@'%'
    if $3; then echo "GRANT USAGE ON *.* TO $(lit "$1")@'%' IDENTIFIED BY $(lit "$2");"
    else echo "CREATE USER $(lit "$1")@'%' IDENTIFIED BY $(lit "$2");"; fi
}
