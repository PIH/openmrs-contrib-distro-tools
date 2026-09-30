# The images the utils/ scripts run their tools in (also openmrs-docker's restore overlays, which
# initialize passes them to). Sourced, not run.
# shellcheck disable=SC2034

ALPINE_IMAGE=alpine:3.21
# 7-Zip 24.08, which reads a password from stdin when it asks for one (see archive.sh).
P7ZIP_IMAGE=partnersinhealth/p7zip
# Percona XtraBackup's innobackupex, for MySQL 5.6 data directories.
PERCONA_IMAGE=partnersinhealth/percona-0.1-4
