"""An instance's data volumes: external to Compose, so no `docker compose down -v` can delete them.

Every volume a service's compose.yaml declares is `external: true`, named `${SERVICE_NAME}_<volume>`
(the name Compose gave it when it managed it, so existing volumes keep working). Compose never
creates or removes an external volume: pihx creates the missing ones, labelled pihx.instance=<name>,
before anything brings containers up, and only destroy removes them (after backing them up). A bare
`docker compose up` with a volume missing fails instead of starting on an empty one.

A bind mount's missing source in the instance directory (e.g. a relative default like
./modality-simulator-config) is made here too, as the caller: Docker would make it as root, which the
caller then can't write to or remove."""

import json
import os
import subprocess
import sys

from pihx import compose as compose_module

# The label pihx gives the volumes it creates: destroy finds an instance's volumes by it, including
# those of services removed since.
LABEL = "pihx.instance"


class VolumeError(Exception):
    """Docker's volumes couldn't be listed, created or removed."""


def _docker(compose, *args):
    return compose_module.docker(["docker", *args], env=compose.environment(),
                                 capture_output=True, text=True)


def model(compose):
    """The resolved compose model (all profiles) of <compose>'s files, as `config --format json`."""
    result = compose.run("--profile", "*", "config", "--format", "json", stdout=subprocess.PIPE,
                         text=True)
    return json.loads(result.stdout or "{}")


def instance_volumes(config, name):
    """The external volumes the model <config> declares for the instance <name>: those named
    <name>_<volume>. Another external volume (e.g. one an override shares between instances) isn't
    the instance's, so pihx never creates or removes it."""
    found = set()
    for key, spec in (config.get("volumes") or {}).items():
        spec = spec or {}
        if spec.get("external") and spec.get("name") == f"{name}_{key}":
            found.add(spec["name"])
    return sorted(found)


def listed(compose, *filters):
    """The names `docker volume ls` gives with <filters> (e.g. label=...). A failed listing is an
    error, never an empty list: what is created or removed is decided from it."""
    result = _docker(compose, "volume", "ls", "-q",
                     *(a for f in filters for a in ("--filter", f)))
    if result.returncode != 0:
        raise VolumeError(f"couldn't list Docker's volumes: {(result.stderr or '').strip()}")
    return set(result.stdout.split())


def bind_sources(config, instance_dir):
    """The sources of the model <config>'s bind mounts that Docker would create if missing, and that
    are in <instance_dir> (after resolving links). Others are the operator's, and outside what pihx
    can see."""
    inside = os.path.realpath(instance_dir)
    found = set()
    for spec in (config.get("services") or {}).values():
        for mount in (spec or {}).get("volumes") or []:
            if not isinstance(mount, dict) or mount.get("type") != "bind" or not mount.get("source"):
                continue
            if not (mount.get("bind") or {}).get("create_host_path"):
                continue
            source = os.path.realpath(mount["source"])
            if os.path.commonpath([inside, source]) == inside and source != inside:
                found.add(source)
    return sorted(found)


def ensure_bind_sources(config, instance_dir):
    """Makes the missing bind sources in <instance_dir> (bind_sources) as the caller, so Docker
    doesn't make them as root."""
    for source in bind_sources(config, instance_dir):
        if os.path.lexists(source):
            continue
        try:
            os.makedirs(source)
        except OSError as e:
            raise VolumeError(f"couldn't make {source} for a bind mount: {e.strerror}") from e
        print(f"Created directory {source}", file=sys.stderr)


def ensure(compose, created=None):
    """Creates the instance's external volumes (from <compose>'s model) that don't exist yet,
    labelled pihx.instance=<name>, and its missing bind sources (ensure_bind_sources), before its
    containers come up. Appends each volume it creates to <created> as it goes (so a caller can
    remove exactly those after a later failure) and returns them."""
    created = [] if created is None else created
    name = compose.instance.name
    config = model(compose)
    ensure_bind_sources(config, compose.instance.dir)
    wanted = instance_volumes(config, name)
    if not wanted:
        return created
    existing = listed(compose)
    for volume in wanted:
        if volume in existing:
            continue
        result = _docker(compose, "volume", "create", "--label", f"{LABEL}={name}", volume)
        if result.returncode != 0:
            raise VolumeError(f"couldn't create the volume {volume}: "
                              f"{(result.stderr or '').strip()}")
        created.append(volume)
        print(f"Created volume {volume}", file=sys.stderr)
    return created


def human(kb):
    """<kb> KiB as 1.2G, 3.4M or 56K."""
    if kb >= 1048576:
        return f"{kb / 1048576:.1f}G"
    if kb >= 1024:
        return f"{kb / 1024:.1f}M"
    return f"{kb}K"
