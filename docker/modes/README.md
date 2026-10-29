# Overlays

Compose files that `openmrs-docker` adds to an instance's own fragments for one command. None of
them is copied into an instance.

- `dev.yaml` and `build.yaml`: for `--dev`, and for `build`/`--build`.

The restore overlays `initialize` uses are the services' own: `services/<svc>/restore/`, named by
each service's manifest (see [Initializing an instance](../../docs/restore.md)).
