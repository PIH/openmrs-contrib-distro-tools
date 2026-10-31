"""archive: a full, cold copy of a stopped instance, which destroy also takes before it deletes
anything.

An archive directory holds one <volume>.tar.gz per volume (the whole volume, numeric owners and
permissions kept, read in a throwaway container that mounts it read-only, and read back with
`tar -t`), copies of the instance's env and override files (0600; the directory is 0700), and
RESTORE.txt, the commands that recreate the instance from them. Its volumes are those destroy would
remove: the instance's external volumes (its compose model), and every volume labelled
pihx.instance=<name> or com.docker.compose.project=<name> (so those of services removed since, and
older Compose-made ones, too).

It refuses while any of the instance's containers is running, so archives are always taken cold,
and checks first that the destination has room for the volumes. Anything that fails removes what it
wrote, so a directory left behind is always complete. It's product-neutral: it knows volumes and
files, not what's in them."""

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from pihx import compose as compose_module, instance as instance_module, lock, volumes
from pihx.commands import CliError
from pihx.commands.instance_cmds import FILE_MODE, option, tools_dir
from pihx.instance import InstanceError

DIR_MODE = 0o700
RESTORE_FILE = "RESTORE.txt"
COMPOSE_PROJECT_LABEL = "com.docker.compose.project"


def note(message):
    print(message, file=sys.stderr)


def _docker(compose, *args, **kwargs):
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return compose_module.docker(["docker", *args], env=compose.environment(), **kwargs)


def stderr_of(result):
    err = result.stderr
    if isinstance(err, bytes):
        err = err.decode(errors="replace")
    return (err or "").strip()


def alpine_image(inst):
    """The tools' ALPINE_IMAGE (utils/lib/images.sh), the one image for chores like this."""
    path = inst.tools / "utils" / "lib" / "images.sh"
    found = re.search(r"^ALPINE_IMAGE=(\S+)", path.read_text(), re.MULTILINE)
    if not found:
        raise InstanceError(f"no ALPINE_IMAGE in {path}")
    return found.group(1)


def _mount(volume):
    """docker run's --mount for <volume> at /v, read-only."""
    return ["--mount", f"type=volume,source={volume},target=/v,readonly"]


def timestamp():
    """(now in UTC for a directory name, and for people)."""
    now = time.gmtime()
    return time.strftime("%Y%m%dT%H%M%SZ", now), time.strftime("%Y-%m-%d %H:%M:%S UTC", now)


# --- what's archived ------------------------------------------------------------------------------

def find_volumes(inst, compose):
    """The instance's volumes: its external volumes that exist (from its compose model), and those
    labelled as its (pihx's label, or Compose's project label). Every listing is checked, so a
    failure stops before anything changes."""
    model = []
    if inst.services:
        try:
            model = volumes.instance_volumes(volumes.model(compose), inst.name)
        except compose_module.ComposeError:
            note(f"warning: Compose can't read {inst.name}'s files, so its volumes are found by "
                 "their labels only.")
    existing = volumes.listed(compose)
    labelled = (volumes.listed(compose, f"label={volumes.LABEL}={inst.name}")
                | volumes.listed(compose, f"label={COMPOSE_PROJECT_LABEL}={inst.name}"))
    return sorted((set(model) & existing) | labelled)


def size_kb(compose, image, volume):
    """What <volume> holds, in KiB, measured in a container that mounts it read-only."""
    result = _docker(compose, "run", "--rm", *_mount(volume), image, "du", "-sk", "/v")
    words = (result.stdout or "").split()
    if result.returncode != 0 or not words or not words[0].isdigit():
        raise CliError(f"couldn't measure the volume {volume}, so nothing was changed: "
                       f"{stderr_of(result)}")
    return int(words[0])


def running_containers(inst, compose):
    """The ids of the instance's running containers (Compose's project label); a failed listing is
    an error."""
    result = _docker(compose, "ps", "-q", "--filter", f"label={COMPOSE_PROJECT_LABEL}={inst.name}")
    if result.returncode != 0:
        raise CliError(f"couldn't list {inst.name}'s containers: {stderr_of(result)}")
    return result.stdout.split()


def refuse_running(inst, compose):
    if running_containers(inst, compose):
        raise CliError(f"{inst.name} is running, and an archive is only taken of a stopped "
                       f"instance: stop it first: pihx {inst.name} stop")


# --- the destination ------------------------------------------------------------------------------

class Destination:
    """The directory an archive is written to: <path>, made here (0700) unless <existing> (a
    directory the caller named, which must be empty). On failure, discard() removes what was
    written, and the directory itself unless it was the caller's (<owned>: made for this run)."""

    def __init__(self, path, existing=False, owned=True):
        self.path = Path(path)
        self.existing = existing
        self.owned = owned
        self.written = []

    def make(self):
        try:
            if self.existing:
                if any(self.path.iterdir()):
                    raise CliError(f"{self.path} isn't empty: an archive goes into a new or empty "
                                   "directory")
            else:
                os.mkdir(self.path, DIR_MODE)
            os.chmod(self.path, DIR_MODE)
        except OSError as e:
            raise CliError(f"can't write the archive to {self.path} ({e.strerror or e}), so "
                           "nothing was changed") from None

    def new_file(self, name):
        """A new file <name> in it (0600), open for writing bytes."""
        path = self.path / name
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, FILE_MODE)
        self.written.append(path)
        return os.fdopen(fd, "wb")

    def discard(self):
        for path in self.written:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        if self.owned:
            shutil.rmtree(self.path, ignore_errors=True)

    def size_kb(self):
        return sum(p.stat().st_size for p in self.written) // 1024


def check_space(dest, needed_kb):
    """Refuses unless <dest>'s filesystem has the volumes' size free, plus 10% (their archives are
    compressed, so usually much smaller). DISK_SPACE_FREE_KB replaces the free space, for tests."""
    free = os.environ.get("DISK_SPACE_FREE_KB")
    if free and free.isdigit():
        free = int(free)
    else:
        stat = os.statvfs(dest.path)
        free = stat.f_bavail * stat.f_frsize // 1024
    if free < needed_kb + needed_kb // 10:
        raise CliError(f"not enough disk space for the archive: the volumes hold "
                       f"{volumes.human(needed_kb)} (plus 10%), and {volumes.human(free)} is free "
                       f"at {dest.path}. Nothing was changed.")
    note(f"Disk space: the volumes hold {volumes.human(needed_kb)}; {volumes.human(free)} free "
         f"at {dest.path}.")


# --- writing it -----------------------------------------------------------------------------------

def archive_volume(compose, image, volume, dest):
    """Writes <volume>.tar.gz, the whole volume with numeric owners and permissions, and reads it
    back."""
    name = f"{volume}.tar.gz"
    note(f"Archiving {volume} to {dest.path / name}")
    with dest.new_file(name) as f:
        result = _docker(compose, "run", "--rm", *_mount(volume), image,
                         "tar", "-czf", "-", "--numeric-owner", "-C", "/v", ".",
                         capture_output=False, text=False, stdout=f, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise CliError(f"couldn't archive the volume {volume}: {stderr_of(result)}")
    path = dest.path / name
    check = subprocess.run(["tar", "-tzf", str(path)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE)
    if check.returncode != 0 or path.stat().st_size == 0:
        raise CliError(f"the archive of {volume} ({path}) doesn't read back: {stderr_of(check)}")


def instance_files(inst):
    """The instance's own files worth keeping: its env files and override files."""
    return [p for p in sorted(inst.dir.iterdir())
            if p.is_file() and not p.name.startswith(".")
            and (p.name.endswith(".env") or p.name.endswith(".override.yaml"))]


def restore_text(inst, image, names, files, folder, taken, command, declared=None):
    """RESTORE.txt. <declared>: the volumes the instance's services declare; any other archived
    volume belonged to a service removed earlier, whose env file is gone."""
    target = inst.dir.parent / inst.name
    leftover = [v for v in names if declared is not None and v not in declared]
    tools = inst.dir / "tools"
    if tools.is_symlink():
        tools_step = f"  ln -s {os.readlink(tools)} {target}/tools"
    else:
        tools_step = (f"  # {inst.name}'s tools were the directory {tools}, not a link: link a "
                      f"tools checkout instead\n  ln -s <tools directory> {target}/tools")
    lines = [
        f"Archive of the pihx instance {inst.name}, taken by 'pihx {inst.name} {command}' at "
        f"{taken}.",
        f"It was {inst.dir}, with the volumes:",
        *(f"  {v}  ({v}.tar.gz)" for v in names),
        "",
        *([f"{', '.join(leftover)} belonged to a service removed before the archive, so its env file "
           "isn't here:",
           "restoring the volume doesn't add the service back; add-service it again to use it.", ""]
          if leftover else []),
        f"To recreate {inst.name} from it, on a host with Docker, as its user ({target} and the "
        "volumes",
        "must not exist):",
        "",
        f"  mkdir -m 700 {target}",
        *(f"  cp -p {folder / f.name} {target}/" for f in files),
        tools_step,
    ]
    for v in names:
        lines += [
            f"  docker volume create --label {volumes.LABEL}={inst.name} {v}",
            f"  docker run --rm -i --mount type=volume,source={v},target=/v {image} \\",
            f"      tar -xzpf - --numeric-owner -C /v < {folder / f'{v}.tar.gz'}",
        ]
    lines += [f"  pihx {inst.name} start", ""]
    return "\n".join(lines)


def write(inst, compose, image, names, dest, taken, command):
    """Fills <dest> (made, space checked) with the archive of <names>; refuses if the instance is
    running, and on any failure discards what it wrote. Returns its size in KiB."""
    try:
        refuse_running(inst, compose)
        for volume in names:
            archive_volume(compose, image, volume, dest)
        files = instance_files(inst)
        for f in files:
            with dest.new_file(f.name) as out:
                out.write(f.read_bytes())
        with dest.new_file(RESTORE_FILE) as out:
            try:
                declared = volumes.instance_volumes(volumes.model(compose), inst.name)
            except compose_module.ComposeError:
                declared = None
            out.write(restore_text(inst, image, names, files, dest.path, taken, command,
                                   declared).encode())
    except BaseException:
        dest.discard()
        raise
    return dest.size_kb()


def prepare(inst, compose, image, dest):
    """The volumes to archive, their sizes, and <dest> made with room checked; nothing is made if
    a check fails. Returns (names, sizes)."""
    names = find_volumes(inst, compose)
    sizes = {v: size_kb(compose, image, v) for v in names}
    dest.make()
    try:
        check_space(dest, sum(sizes.values()))
    except BaseException:
        dest.discard()
        raise
    return names, sizes


# --- the command ----------------------------------------------------------------------------------

def destination(name, to):
    """The Destination for --to=<to>, or the default $PIHX_HOME/<name>.archive-<time>. The launcher
    resolves <to> on the host, mounts it and says so in PIHX_TO (and PIHX_TO_CREATED=1 when it made
    it, empty)."""
    if to is None:
        return Destination(instance_module.home() / f"{name}.archive-{timestamp()[0]}")
    resolved = os.environ.get("PIHX_TO")
    if not resolved:
        raise CliError(f"--to {to}: run pihx through bin/pihx, which mounts the directory")
    if not Path(resolved).is_dir():
        raise CliError(f"--to {to}: {resolved} isn't a directory")
    # One the launcher made for this run is removed again if the archive fails.
    return Destination(resolved, existing=True, owned=os.environ.get("PIHX_TO_CREATED") == "1")


def cmd_archive(name, args):
    to, rest = option(args, "to")
    if rest:
        raise CliError(f"unknown option '{rest[0]}' for archive (usage: pihx {name} archive "
                       "[--to=<dir>])", status=2)
    if to == "":
        raise CliError("--to needs a directory", status=2)
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    compose = compose_module.Compose(inst)
    dest = destination(name, to)
    with lock.hold(inst, lock.wait_seconds(), command="archive"):
        image = alpine_image(inst)
        refuse_running(inst, compose)
        names, _ = prepare(inst, compose, image, dest)
        kb = write(inst, compose, image, names, dest, timestamp()[1], "archive")
    print(f"Archived {name} to {dest.path}/ ({volumes.human(kb)}); {RESTORE_FILE} there says how "
          "to recreate it.")
    return 0
