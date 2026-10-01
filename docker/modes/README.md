# Overlays

Compose files that `openmrs-docker` adds to an instance's own fragments for one command. None of
them is copied into an instance.

- `dev.yaml` and `build.yaml`: for `--dev`, and for `build`/`--build`.
- `restore-*.yaml` and `reset-mysql-accounts.yaml`: for `initialize`, one per source of each volume
  (see `lib/openmrs-docker/initialize.sh`). Each adds one-shot containers that fill a volume before
  `openmrs-db` first starts.

What the `initialize` overlays have in common:

- `initialize` only starts `openmrs-db`, so every restore container is an `openmrs-db` dependency,
  including those that fill `openmrs-data`.
- The variables they need beyond the instance's env are set by `initialize` for that one run and
  not written to env: the absolute `RESTORE_*_PATH`, the name the source is mounted as
  (`archive.<ext>`, `dump.sql[.gz]` or `backup`, so the right extractor or import runs),
  `DISTRO_TOOLS_UTILS_DIR`, and `P7ZIP_IMAGE`/`PERCONA_IMAGE` from `utils/lib/images.sh`.
- Archives are extracted by `utils/lib/in-container/extract.sh`, into a volume, never onto the host.
  `ARCHIVE_PASSWORD` is passed by name and reaches 7z on stdin.
- The temporary volumes they use (`db-init`, `percona-staging`) are removed by `initialize`
  afterwards, and by `destroy`.
- A physical restore (`RESTORE_MYSQL_DATA_PATH`, `RESTORE_MYSQL_PERCONA_PATH`) brings the source
  server's MySQL accounts, so `reset-mysql-accounts.yaml` sets them to the instance's.
