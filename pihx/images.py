"""Images built from this repo (images/<name>/ and services/<svc>/image/), as compose files refer to
them.

Each is partnersinhealth/<name>:<tag>, where the tag is the hash of its directory
(utils/hash-directory.sh), the tag CI publishes (build-images.yml). Compose files name one by the
variable PIHX_IMAGE_<NAME> (upper case, '-' as '_'; e.g. PIHX_IMAGE_BACKUP_TOOLS), which pihx sets,
so an instance always runs the image that matches its checkout and never `latest`. Only the images
an instance's compose files name are hashed, so a broken image directory affects only the instances
that use it.

A tag that isn't published yet (a change not merged, or not built by CI yet) is built here from the
checkout, as bin/pihx builds pihx-runtime: ensure() runs before anything brings containers up. An
image directory with a `platforms` file (e.g. linux/amd64) is built for only those, and isn't built
on another host."""

import functools
import platform
import subprocess
import sys
from pathlib import Path

from pihx import compose as compose_module

REPOSITORY = "partnersinhealth"
PREFIX = "PIHX_IMAGE_"
# Docker's names for the architectures platform.machine() reports.
ARCHITECTURES = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


class ImageError(Exception):
    """An image of this repo couldn't be hashed, pulled or built."""


def variable(name):
    """The variable compose files name the image <name> by."""
    return PREFIX + name.upper().replace("-", "_")


def directories(tools):
    """{image name: its directory} for every image the tools directory <tools> builds."""
    tools = Path(tools)
    found = {}
    for d in sorted(tools.glob("images/*/")):
        found[d.name] = d
    for d in sorted(tools.glob("services/*/image/")):
        found[d.parent.name] = d
    return found


def named(tools, compose_files):
    """{image name: its directory} for the images of <tools> whose variable one of <compose_files>
    mentions."""
    text = "".join(Path(f).read_text() for f in compose_files if Path(f).is_file())
    if PREFIX not in text:
        return {}
    return {name: d for name, d in directories(tools).items() if variable(name) in text}


@functools.lru_cache(maxsize=None)
def _tag(tools, directory):
    result = subprocess.run([str(Path(tools) / "utils" / "hash-directory.sh"), str(directory)],
                            capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        raise ImageError(f"couldn't hash {directory}: {result.stderr.strip()}")
    return result.stdout.strip()


def _reference(tools, name, directory):
    return f"{REPOSITORY}/{name}:{_tag(str(tools), str(directory))}"


def references(tools, compose_files):
    """{PIHX_IMAGE_<NAME>: partnersinhealth/<name>:<tag>} for the images of <tools> that
    <compose_files> name."""
    return {variable(name): _reference(tools, name, d)
            for name, d in named(tools, compose_files).items()}


def platforms(directory):
    """The platforms the image in <directory> is built for (its `platforms` file), or None for
    CI's default set."""
    path = Path(directory) / "platforms"
    if not path.is_file():
        return None
    # As build-images.yml reads it: comma-separated, whitespace ignored.
    return [p for p in "".join(path.read_text().split()).split(",") if p]


def host_platform():
    machine = platform.machine().lower()
    return f"linux/{ARCHITECTURES.get(machine, machine)}"


def _docker(compose, *args, **kwargs):
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return compose_module.docker(["docker", *args], env=compose.environment(), **kwargs)


def used(compose, config):
    """{image reference: its directory} for the images of this repo that the resolved compose model
    <config> runs."""
    tools = compose.instance.tools
    by_reference = {_reference(tools, name, d): d
                    for name, d in named(tools, compose.compose_files()).items()}
    wanted = {(spec or {}).get("image") for spec in (config.get("services") or {}).values()}
    return {ref: d for ref, d in by_reference.items() if ref in wanted}


def ensure(compose):
    """Makes sure each image of this repo that the instance runs is here: there already, pulled, or
    (not published yet) built from the checkout. Reads the compose model only when one of its files
    names such an image."""
    if not named(compose.instance.tools, compose.compose_files()):
        return
    from pihx import volumes   # (it imports compose too)
    for reference, directory in sorted(used(compose, volumes.model(compose)).items()):
        if _docker(compose, "image", "inspect", reference).returncode == 0:
            continue
        if _docker(compose, "pull", "-q", reference).returncode == 0:
            continue
        supported = platforms(directory)
        if supported and host_platform() not in supported:
            raise ImageError(f"{reference} is built for {', '.join(supported)} only, and this host is "
                             f"{host_platform()}: it isn't published for this host, and can't be "
                             f"built here ({directory / 'platforms'})")
        print(f"{reference} isn't published yet; building it from {directory}", file=sys.stderr)
        result = _docker(compose, "build", "-q", "-t", reference, str(directory))
        if result.returncode != 0:
            raise ImageError(f"couldn't build {reference} from {directory}: "
                             f"{(result.stderr or '').strip()}")
