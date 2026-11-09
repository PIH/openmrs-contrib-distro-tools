<!-- Drafted by Claude (Claude Opus 5.5) via Claude Code for TASKS-652 review; agree with the team before merging. -->
# Working on openmrs-contrib-distro-tools

`pihx` (and its OpenMRS extension, `openmrs-docker`) is maintained mostly through Claude Code, by
developers who are not Python specialists. Keep the code plain: obvious control flow over clever
idioms, docstrings that say why, and the style of the file you are in. Start with
[Developing this tool](docs/development.md).

## How it runs: only in pihx-runtime

- pihx runs only through `bin/pihx` (and `bin/openmrs-docker`), which start it in the
  `partnersinhealth/pihx-runtime` image (`images/pihx-runtime/Dockerfile`). The tests run through
  `test/run`, which uses the same image. The host needs only Docker and a shell.
- Never run pihx code with the host's `python3`, never `pip install` anything outside the image's
  Dockerfile, and never create a venv. If something seems to need one, it belongs in the image
  (below) or is a bug.
- `PIHX_DEBUG=1` echoes every docker command and shows Python tracebacks.

## Dependencies

The policy, and how to change it, is in [Dependencies](docs/development.md#dependencies). In short:

- Python's standard library plus PyYAML, both from the image (Alpine's `python3` and `py3-yaml`).
  There is no `requirements.txt` or `pyproject.toml`, by design.
- Adding a package is a team decision: ask before doing it. Prefer the Alpine `py3-*` package on the
  image's `apk add` line; if Alpine doesn't package it, `pip install` it in the Dockerfile, pinned to
  an exact version (`name==1.2.3`). Either way, `pihx/tests/test_imports.py` must allow it.
- Any change under `images/pihx-runtime/` is a new image tag ([Image tags](docs/development.md#image-tags)),
  so don't add files there that the image doesn't need.

## Boundaries

- `pihx/` is product-neutral: no product names, no `if service == ...`. What a service needs goes in
  its own `services/<svc>/` ([Writing a service](docs/services.md#writing-a-service)); OpenMRS
  specifics go in `openmrs/`.
- `utils/` and the scripts under `services/` stay Bash.

## Tests

`test/run unit` for Python changes; `test/run static` and `test/run args` for scripts, compose files,
docs and the launcher (seconds); `test/run integration` (minutes) for anything that touches volumes,
restore or a service's containers. Details: [Testing this project](docs/development.md#testing-this-project).

## Safety rules not to weaken

These protect real data. Change one only when the task is explicitly about it.

- Volumes are external: pihx creates them, and `docker compose down -v` can't remove them
  ([Volumes](docs/instances.md#volumes)).
- `destroy` lists what it will delete, needs the instance's name typed, archives everything first,
  then needs `delete` typed. There is no `--force` ([Archive and destroy](docs/instances.md#archive-and-destroy)).
- `initialize` refuses volumes that already exist, and on failure removes only what it made
  ([Restore](docs/services.md#restore)).
- One command at a time per instance, under its lock ([One command at a time](docs/instances.md#one-command-at-a-time)).
- `pihx <instance> compose` passes only an allow-list of subcommands (`config`, `ps`, `logs`, `exec`, ...);
  `up`, `down`, `run` and the rest go through pihx's own commands
  ([Compose on the instance](docs/instances.md#compose-on-the-instance)).
- Scripts and output never print env values or secrets (no `env`, no `set -x`); `config` masks them.
- Everything pihx writes on the host belongs to the calling user.
- Images this repo builds are referenced by content tag, never `latest`.

## Docs

Docs change with the code they describe, in the same PR; `test/static/docs.bats` checks every
relative link. This repo's `docs/` is the as-built record. The design and plan in mirebalais-puppet
(`docs/docker-migration/designs/2026-10-29-pihx-restructure*.md`) are history, and differ from what
was built in places.
