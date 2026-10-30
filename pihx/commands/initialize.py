"""initialize: fills a new instance's volumes from a directory (or an image's /seed directory) before its
first start, each service from its own entry, through the restore overlays its manifest declares.

The directory holds at most one entry per service, named as that service's manifest accepts
(`restore: [{names, overlay, after?}]`); a service with no entry starts empty. Every chosen
overlay (and its `after`) is added to the instance's compose files for one `up` of the containers
they name: a container with a healthcheck must turn healthy (e.g. a database importing a dump),
the others must exit 0. Then everything is brought down and the restore-only volumes go.

Paths are the host's: the launcher mounts the directory at its own path, and the daemon resolves what
the overlays mount."""

import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from pihx import compose as compose_module, envfile, instance as instance_module, lock, script
from pihx import services as services_module
from pihx.commands import CliError
from pihx.commands.instance_cmds import tools_dir

USAGE = "usage: pihx <instance> initialize --from <dir> | --from-image <image>"
# What an archive is mounted as, archive.<ext>, so the extractor knows it (utils/lib/in-container/
# extract.sh); tgz is extracted as tar.gz.
ARCHIVE_EXTENSIONS = ("7z", "zip", "tar.gz", "tgz", "tar")
# The directory a seed image holds.
SEED_DIR = "/seed"
VARIABLE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)")
DEFAULT_TIMEOUT = 3600


def note(message):
    print(message, file=sys.stderr)


@dataclasses.dataclass
class Choice:
    """A directory entry, and the service and restore entry that take it."""
    service: object
    restore: object
    entry: str
    path: Path

    def overlays(self):
        return [self.service.dir / o for o in filter(None, (self.restore.overlay,
                                                             self.restore.after))]


def archive_name_for(name):
    """archive.<ext> for an archive's name, or None if it isn't one."""
    for ext in ARCHIVE_EXTENSIONS:
        if name.endswith(f".{ext}"):
            return f"archive.{'tar.gz' if ext == 'tgz' else ext}"
    return None


def _variable_prefix(service_name):
    return service_name.upper().replace("-", "_")


class EntryError(CliError):
    """The directory's entries don't fit the instance's services."""


def choose(inst, folder, entries, label=None):
    """The Choice for each of <entries> ((name, "dir" | "file" | None if unknown), in <dir>).
    An entry no service of the instance accepts, or a second entry for one service, is an
    EntryError, naming the directory as <label> if given."""
    where = label or str(folder)
    accepted = {}
    for svc in inst.services:
        for restore in svc.manifest.restore:
            for name in restore.names:
                accepted[name.rstrip("/")] = (svc, restore, name.endswith("/"))
    others = {}
    for name, svc in services_module.all(inst.tools).items():
        if name not in {s.name for s in inst.services}:
            for restore in svc.manifest.restore:
                for n in restore.names:
                    others[n.rstrip("/")] = name
    chosen = {}
    for name, kind in sorted(entries):
        if name not in accepted:
            if name in others:
                raise EntryError(f"{where}/{name} is for {others[name]}, which isn't part of "
                                 f"{inst.name} (add it with 'pihx {inst.name} add-service "
                                 f"{others[name]}', or leave the entry out)")
            raise EntryError(f"{where}/{name} matches no service of {inst.name}: each entry is "
                             "named as a service's manifest accepts (its `restore` names), and "
                             "nothing else may be in the directory")
        svc, restore, is_dir = accepted[name]
        if kind == "file" and is_dir:
            raise EntryError(f"{where}/{name} must be a directory for {svc.name}")
        if kind == "dir" and not is_dir:
            raise EntryError(f"{where}/{name} must be a file for {svc.name}")
        if svc.name in chosen:
            raise EntryError(f"{where} has two entries for {svc.name}: "
                             f"{chosen[svc.name].entry} and {name}; keep one")
        chosen[svc.name] = Choice(svc, restore, name, folder / name)
    return list(chosen.values())


def restore_variables(choices):
    """For each restored service <SVC> (its name in capitals, '-' as '_'): <SVC>_RESTORE_PATH, the
    entry's host path; <SVC>_RESTORE_NAME, its name; and for an archive <SVC>_RESTORE_ARCHIVE, the
    archive.<ext> name to mount it as."""
    values = {}
    for choice in choices:
        prefix = _variable_prefix(choice.service.name)
        values[f"{prefix}_RESTORE_PATH"] = str(choice.path)
        values[f"{prefix}_RESTORE_NAME"] = choice.entry
        archive = archive_name_for(choice.entry)
        if archive:
            values[f"{prefix}_RESTORE_ARCHIVE"] = archive
    return values


def referenced_variables(path):
    """The names an overlay interpolates (${NAME...}) or passes through from the environment
    (an `environment:` entry with no value)."""
    names = set(VARIABLE.findall(Path(path).read_text()))
    data = services_module.read_overlay(path)
    for spec in (data.get("services") or {}).values():
        env = (spec or {}).get("environment") or []
        if isinstance(env, list):
            names |= {e for e in env if isinstance(e, str) and "=" not in e}
        else:
            names |= {k for k, v in env.items() if v is None}
    return names


def from_folder(arg):
    """The directory --from names, as the host has it: the launcher resolves it (PIHX_FROM) and mounts
    it at that path. Otherwise <arg> against the caller's directory, if it's under a path the
    launcher mounts anyway."""
    resolved = os.environ.get("PIHX_FROM")
    if resolved:
        folder = Path(resolved)
    else:
        cwd = os.environ.get("PIHX_CWD") or os.getcwd()
        folder = Path(os.path.realpath(os.path.join(cwd, arg)))
        mounted = [instance_module.home(), tools_dir()]
        if not any(folder == m or m in folder.parents for m in mounted):
            # The launcher mounts an existing directory outside them, and says so in PIHX_FROM.
            raise CliError(f"--from {arg}: {folder} isn't a directory pihx can see (bin/pihx "
                           "mounts one outside its own paths)")
    if not folder.is_dir():
        raise CliError(f"--from {arg}: {folder} isn't a directory")
    return folder


def _entries(folder):
    found = []
    for entry in sorted(os.listdir(folder)):
        path = folder / entry
        # A link the host resolves (to a path not mounted here) can't be checked here.
        kind = "dir" if path.is_dir() else "file" if path.exists() else None
        found.append((entry, kind))
    return found


def _parse_args(name, args):
    sources = []
    i = 0
    while i < len(args):
        arg = args[i]
        for option in ("--from", "--from-image"):
            if arg == option:
                if i + 1 >= len(args):
                    raise CliError(f"{option} needs a value ({USAGE})", status=2)
                sources.append((option, args[i + 1]))
                i += 1
                break
            if arg.startswith(f"{option}="):
                sources.append((option, arg.split("=", 1)[1]))
                break
        else:
            raise CliError(f"unknown option '{arg}' for initialize ({USAGE})", status=2)
        i += 1
    if len(sources) != 1 or not sources[0][1]:
        raise CliError(USAGE.replace("<instance>", name), status=2)
    return sources[0]


# --- docker ---------------------------------------------------------------------------------------

def _docker(env, *args, **kwargs):
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return compose_module.docker(["docker", *args], env=env, **kwargs)


def tool_images(inst):
    """The images utils/lib/images.sh names (ALPINE_IMAGE, P7ZIP_IMAGE, PERCONA_IMAGE, ...), which
    the overlays run their tools in."""
    text = (inst.tools / "utils" / "lib" / "images.sh").read_text()
    return dict(re.findall(r"^([A-Z][A-Z0-9_]*_IMAGE)=(\S+)", text, re.MULTILINE))


def _bind(path, target):
    """docker run's --mount for <path> on the host, read-only. Unlike -v, it fails when the path
    doesn't exist (e.g. a dangling link), instead of mounting a new empty directory."""
    return ["--mount", f'type=bind,"source={path}",target={target},readonly']


def check_entries(env, images, choices):
    """Each entry exists on the host, as the daemon sees it: a link here may point to a path that
    isn't mounted in pihx's container, and a missing one would otherwise restore nothing."""
    for choice in choices:
        result = _docker(env, "run", "--rm", *_bind(choice.path, "/entry"),
                         images["ALPINE_IMAGE"], "true")
        if result.returncode != 0:
            raise CliError(f"{choice.path} doesn't exist on the host (a dangling link?), so "
                           f"there's nothing to restore {choice.service.name} from: "
                           f"{result.stderr.strip()}")


# --- disk space -----------------------------------------------------------------------------------

_SIZE_SCRIPT = r'''
case "$1" in
    dir) du -sk /s | cut -f1 ;;
    gz) c=$(stat -c %s /s); u=$(tail -c 4 /s | od -An -tu4 | tr -d " ")
        [ "$u" -ge "$c" ] || u=$c; echo $(( (u + 1023) / 1024 )) ;;
    *) echo $(( ($(stat -c %s /s) + 1023) / 1024 )) ;;
esac
'''


def _size_kb(env, images, choice):
    """What restoring <choice> writes, in KiB, measured in containers (the host path may be a link,
    or unreadable to the caller): a directory's size; a file's contents (uncompressed); twice an
    archive's contents, extracted before it is imported or copied. None if it can't be told."""
    path, archive = str(choice.path), archive_name_for(choice.entry)
    if archive in ("archive.7z", "archive.zip"):
        result = _docker(env, "run", "--rm", "-e", "ARCHIVE_PASSWORD",
                         *_bind(path, f"/a/{archive}"), images["P7ZIP_IMAGE"], "sh", "-c",
                         f'printf "%s\\n" "${{ARCHIVE_PASSWORD:-}}" | 7z l -slt /a/{archive}')
        if result.returncode != 0:
            return None
        total = sum(int(v) for v in re.findall(r"^Size = (\d+)$", result.stdout, re.MULTILINE))
        return 2 * ((total + 1023) // 1024)
    mode = ("dir" if _is_dir_entry(choice) else
            "gz" if choice.entry.endswith((".gz", ".tgz")) else "file")
    result = _docker(env, "run", "--rm", *_bind(path, "/s"), images["ALPINE_IMAGE"],
                     "sh", "-c", _SIZE_SCRIPT, "sh", mode)
    kb = result.stdout.strip()
    if result.returncode != 0 or not kb.isdigit():
        return None
    return int(kb) * (2 if archive else 1)


def _is_dir_entry(choice):
    return any(n.rstrip("/") == choice.entry and n.endswith("/") for n in choice.restore.names)


def _human(kb):
    if kb >= 1048576:
        return f"{kb / 1048576:.1f}G"
    if kb >= 1024:
        return f"{kb / 1024:.1f}M"
    return f"{kb}K"


def check_space(env, images, choices):
    """Refuses, before any volume exists, if Docker's volumes clearly haven't room (as
    utils/lib/disk-space.sh: needs plus 10%; SKIP_DISK_SPACE_CHECK=true skips it,
    DISK_SPACE_FREE_KB replaces the free space, for tests)."""
    what = "restoring the instance's volumes"
    sizes = [_size_kb(env, images, c) for c in choices]
    if any(s is None for s in sizes):
        note(f"warning: couldn't estimate the disk space {what} needs; not checked.")
        return
    needed = sum(sizes)
    if needed == 0:
        return
    if os.environ.get("SKIP_DISK_SPACE_CHECK") == "true":
        note(f"Disk space: {what} needs about {_human(needed)}; not checked "
             "(SKIP_DISK_SPACE_CHECK=true).")
        return
    free = os.environ.get("DISK_SPACE_FREE_KB")
    if not free:
        result = _docker(env, "run", "--rm", "-v", "/v", images["ALPINE_IMAGE"], "df", "-Pk", "/v")
        lines = result.stdout.splitlines()
        free = lines[1].split()[3] if result.returncode == 0 and len(lines) > 1 else ""
    if not free.isdigit():
        note("warning: couldn't measure the free space on Docker's volumes; not checked.")
        return
    free = int(free)
    if free < needed + needed // 10:
        raise CliError(f"not enough disk space on Docker's volumes: {what} needs about "
                       f"{_human(needed)} (plus 10%), and {_human(free)} is free. Free up space, "
                       "or set SKIP_DISK_SPACE_CHECK=true to go ahead anyway.")
    note(f"Disk space: {what} needs about {_human(needed)}; {_human(free)} free on Docker's "
         "volumes.")


# --- the restore ----------------------------------------------------------------------------------

class Restore:
    """One initialize run on <inst> from <choices>."""

    def __init__(self, inst, choices):
        self.inst = inst
        self.choices = choices
        self.overlays = [o for c in choices for o in c.overlays()]
        self.base = compose_module.Compose(inst)
        self.config = inst.config()
        self.images = tool_images(inst)
        self.extra = {**self.images, **restore_variables(choices)}
        # What the overlays take from the caller, for this run only: values the instance doesn't
        # set (e.g. ARCHIVE_PASSWORD), passed by name, never written anywhere.
        for overlay in self.overlays:
            for name in referenced_variables(overlay):
                if name not in self.config and name not in self.extra and os.environ.get(name):
                    self.extra[name] = os.environ[name]
        self.data = {o: services_module.read_overlay(o) for o in self.overlays}
        self.compose = self._compose()

    def _compose(self):
        return compose_module.Compose(self.inst, extra_files=self.overlays, extra_env=self.extra)

    def env(self):
        return self.compose.environment()

    def _exists(self, volume):
        return _docker(self.env(), "volume", "inspect", volume).returncode == 0

    def project_volumes(self):
        result = _docker(self.env(), "volume", "ls", "-q", "--filter",
                         f"label=com.docker.compose.project={self.inst.name}")
        return set(result.stdout.split())

    def volumes_to_be_new(self):
        """The volumes of every service of the instance that declares a restore: those its own
        containers mount and those its overlays mount or declare. External volumes aren't the
        instance's (e.g. a shared backups volume), so they're left out."""
        config = json.loads(self.base.run("--profile", "*", "config", "--format", "json",
                                          stdout=subprocess.PIPE, text=True).stdout or "{}")
        top = config.get("volumes") or {}

        def name_of(volume):
            spec = top.get(volume) or {}
            if spec.get("external"):
                return None
            return spec.get("name") or f"{self.inst.name}_{volume}"

        names = set()
        for svc in self.inst.services:
            if not svc.manifest.restore:
                continue
            own = services_module.parse_yaml(svc.compose_file.read_text()).get("services") or {}
            for container in own:
                for volume in (config.get("services", {}).get(container) or {}).get("volumes", []):
                    if volume.get("type") == "volume" and volume.get("source"):
                        names.add(name_of(volume["source"]))
            for overlay in svc.restore_overlays():
                declared, mounted = services_module.overlay_volumes(
                    services_module.read_overlay(overlay))
                names |= {name_of(v) for v in declared | mounted}
        return sorted(n for n in names if n)

    def refuse_existing_volumes(self):
        for volume in self.volumes_to_be_new():
            if self._exists(volume):
                raise CliError(f"{volume} already exists -- initialize only runs against a "
                               "brand-new instance with no existing data. Run "
                               f"'pihx {self.inst.name} destroy' first if you really want to "
                               "start over.")

    # --- hooks: services/<svc>/restore/prepare and finish, run in pihx's container ---------------

    def _run_hook(self, svc, hook):
        path = svc.dir / "restore" / hook
        if not path.is_file():
            return None
        result = script.run(self.inst, path, extra_env=self.extra, service=svc,
                            stdout=subprocess.PIPE,
                            text=True, label=f"{svc.name}: restore/{hook}")
        if result.returncode != 0:
            raise CliError(f"{svc.name}: restore/{hook} failed (exit {result.returncode})")
        return result.stdout

    def prepare(self):
        """Each restored service's restore/prepare, before anything is created: its KEY=value lines
        are values for this run only (e.g. openmrs' OPENMRS_DATA_OWNER)."""
        for choice in self.choices:
            out = self._run_hook(choice.service, "prepare")
            for line in (out or "").splitlines():
                if not line.strip():
                    continue
                match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", line, re.DOTALL)
                if not match:
                    # Never the line: it may hold a secret.
                    raise CliError(f"{choice.service.name}: restore/prepare printed a malformed "
                                   "line (not KEY=value)")
                self.extra[match.group(1)] = match.group(2)
        self.compose = self._compose()

    def finish(self):
        """Each restored service's restore/finish, once its volumes are filled."""
        for choice in self.choices:
            out = self._run_hook(choice.service, "finish")
            if out:
                sys.stderr.write(out)

    # --- the run ----------------------------------------------------------------------------------

    def containers(self):
        """The containers the overlays name, which `up` starts (with their dependencies)."""
        names = []
        for data in self.data.values():
            names += [n for n in (data.get("services") or {}) if n not in names]
        return names

    def run(self):
        services = self.containers()
        self.compose.run("up", "-d", *services)
        one_shot, healthy = [], []
        for svc in services:
            ids = self.compose.run("ps", "-a", "-q", svc, stdout=subprocess.PIPE,
                                   text=True).stdout.split()
            for cid in ids:
                check = _docker(self.env(), "inspect", "-f",
                                "{{with .Config.Healthcheck}}{{index .Test 0}}{{end}}", cid)
                (healthy if check.stdout.strip() not in ("", "NONE") else one_shot).append(
                    (svc, cid))
        for svc, cid in one_shot:
            code = _docker(self.env(), "wait", cid).stdout.strip()
            logs = _docker(self.env(), "logs", cid, capture_output=False, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
            sys.stderr.write(logs.stdout)
            if code != "0":
                raise CliError(f"{svc} failed (exit {code or 'unknown'}; its output is above)")
        timeout = os.environ.get("PIHX_INITIALIZE_TIMEOUT") or str(DEFAULT_TIMEOUT)
        for svc, cid in healthy:
            result = subprocess.run(
                [str(self.inst.tools / "utils" / "wait-for-healthy.sh"), f"--container={cid}",
                 f"--timeout={timeout}"], env=self.env())
            if result.returncode != 0:
                raise CliError(f"{svc} didn't become healthy")
        self.compose.run("down")

    def remove_volumes(self, names):
        """Removes those of <names> that exist; returns those still there."""
        present = [n for n in names if self._exists(n)]
        if present:
            _docker(self.env(), "volume", "rm", *present)
        return [n for n in present if self._exists(n)]

    def restore_volumes(self):
        declared = set()
        for data in self.data.values():
            declared |= services_module.overlay_volumes(data)[0]
        return [f"{self.inst.name}_{v}" for v in sorted(declared)]


def _leftovers(volumes):
    text = ", ".join(volumes)
    if any(v.endswith("_db-init") for v in volumes):
        text += " (db-init holds a full copy of the restored dump)"
    return text


def restore_folder(inst, folder, label=None):
    """Restores <inst>'s services from the entries in <dir> (named <label> in messages). The
    caller holds the instance lock."""
    choices = choose(inst, folder, _entries(folder), label)
    if not choices:
        raise CliError(f"{label or folder} holds nothing to restore for {inst.name}")
    for choice in choices:
        note(f"{choice.service.name}: {choice.entry}")
    restore = Restore(inst, choices)
    restore.refuse_existing_volumes()
    check_entries(restore.env(), restore.images, choices)
    check_space(restore.env(), restore.images, choices)
    restore.prepare()
    before = restore.project_volumes()
    env_files = {p: p.read_bytes() for p in inst.dir.glob("*.env")}
    try:
        restore.run()
        left = restore.remove_volumes(restore.restore_volumes())
        if left:
            # The restore itself worked: destroy would remove it too.
            note(f"warning: couldn't remove the staging volume(s) {_leftovers(left)}; remove "
                 "them with 'docker volume rm'.")
        restore.finish()
    except BaseException as e:
        if isinstance(e, compose_module.ComposeError):
            # `up` failed on a container it waited for, whose output (e.g. 7z's "Wrong password")
            # is the clue; down removes it.
            logs = restore.compose.run("logs", "--tail=20", check=False, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True)
            sys.stderr.write(logs.stdout or "")
        restore.compose.run("down", check=False, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
        made = sorted(set(restore.restore_volumes()) | (restore.project_volumes() - before))
        left = restore.remove_volumes(made)
        # A finish hook may have written to an env file before a later one failed.
        for path in inst.dir.glob("*.env"):
            if path not in env_files:
                path.unlink()
        for path, content in env_files.items():
            if path.read_bytes() != content:
                path.write_bytes(content)
        if not isinstance(e, Exception):
            raise
        if left:
            raise CliError(f"initialize failed: {e}. Couldn't remove {_leftovers(left)}: run "
                           f"'pihx {inst.name} destroy' before retrying.") from None
        raise CliError(f"initialize failed: {e}. The containers and volumes it made are "
                       "removed.") from None


# --- seed images ----------------------------------------------------------------------------------

def _copy_seed(inst, image, env):
    """Copies <image>'s /seed directory into a new temporary directory in the instance directory (under
    PIHX_HOME, mounted at its host path, so the restore containers can mount what's in it; and the
    instance's own, so writable where PIHX_HOME isn't, e.g. /home). Returns (directory, pulled)."""
    pulled = _docker(env, "image", "inspect", image).returncode != 0
    if pulled:
        note(f"Pulling {image}")
        result = _docker(env, "pull", "-q", image)
        if result.returncode != 0:
            raise CliError(f"couldn't pull {image}: {result.stderr.strip()}")
    folder = Path(tempfile.mkdtemp(prefix=".seed-", dir=inst.dir))
    try:
        created = _docker(env, "create", image, "none")
        if created.returncode != 0:
            raise CliError(f"couldn't create a container of {image}: {created.stderr.strip()}")
        cid = created.stdout.strip()
        try:
            copied = _docker(env, "cp", f"{cid}:{SEED_DIR}/.", f"{folder}/")
            if copied.returncode != 0:
                raise CliError(f"{image} has no {SEED_DIR} directory to restore from: "
                               f"{copied.stderr.strip()}")
        finally:
            _docker(env, "rm", cid)
    except BaseException:
        shutil.rmtree(folder, ignore_errors=True)
        raise
    return folder, pulled


class SeedError(CliError):
    """An image's /seed directory holds entries no service of the instance restores (an extension may
    say what such a seed probably is)."""


def restore_image(inst, image):
    """Restores <inst>'s services from <image>'s /seed directory, copied into a temporary directory.
    The image is removed afterwards if this pulled it. The caller holds the instance lock."""
    env = compose_module.Compose(inst).environment()
    folder, pulled = _copy_seed(inst, image, env)
    try:
        restore_folder(inst, folder, label=f"{image}:{SEED_DIR}")
    except EntryError as e:
        held = ", ".join(sorted(os.listdir(folder))) or "nothing"
        raise SeedError(f"{image} isn't a seed this version restores: its {SEED_DIR} holds "
                        f"{held} ({e})") from None
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    # A seed is used once: removed if this run pulled it, kept if it was here already (e.g. built
    # locally, and maybe in no registry).
    if pulled and _docker(env, "image", "rm", image).returncode == 0:
        note(f"Removed {image}, pulled for this command")


def cmd_initialize(name, args):
    option, value = _parse_args(name, args)
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    with lock.hold(inst, lock.wait_seconds(), command="initialize"):
        if option == "--from":
            restore_folder(inst, from_folder(value))
        else:
            restore_image(inst, value)
    print(f"Initialized {name}.")
    return 0
