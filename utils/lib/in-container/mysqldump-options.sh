# Sourced by backup-mysqldump and the in-container backup scripts: the mysqldump options for a backup.
# --single-transaction: a consistent snapshot, without locking tables. --flush-logs: starts a new
# binlog, a clean point for purging the older ones.
# shellcheck shell=bash disable=SC2034
MYSQLDUMP_BACKUP_OPTIONS="--single-transaction --flush-logs --routines --triggers"
