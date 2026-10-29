"""initialize: fills a new instance's volumes from a folder (or an image's /seed folder) before its
first start, each service from its own entry, through the restore overlays its manifest declares.

The folder holds at most one entry per service, named as that service's manifest accepts
(`restore: [{names, overlay, after?}]`); a service with no entry starts empty. Every chosen
overlay (and its `after`) is added to the instance's compose files for one `up` of the containers
they name: a container with a healthcheck must turn healthy (e.g. a database importing a dump),
the others must exit 0. Then everything is brought down and the restore-only volumes go.

Paths are the host's: the launcher mounts the folder at its own path, and the daemon resolves what
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

from pihx import compose as compose_module, envfile, instance as instance_module, lock
from pihx import services as services_module
from pihx.commands import CliError
from pihx.commands.instance_cmds import tools_dir

USAGE = "usage: pihx <instance> initialize --from <folder> | --from-image <image>"
# What an archive is mounted as, archive.<ext>, so the extractor knows it (utils/lib/in-container/
# extract.sh); tgz is extracted as tar.gz.
ARCHIVE_EXTENSIONS = ("7z", "zip", "tar.gz", "tgz", "tar")
# The folder a seed image holds.
SEED_DIR = "/seed"
VARIABLE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)")
DEFAULT_TIMEOUT = 3600


def note(message):
    print(message, file=sys.stderr)


@dataclasses.dataclass
class Choice:
    """A folder entry, and the service and restore entry that take it."""
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


def choose(inst, folder, entries):
    """The Choice for each of <entries> ((name, "dir" | "file" | None if unknown), in <folder>).
    An entry no service of the instance accepts, or a second entry for one service, is an error."""
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
                raise CliError(f"{folder / name} is for {others[name]}, which isn't part of "
                               f"{inst.name} (add it with 'pihx {inst.name} add-service "
                               f"{others[name]}', or leave the entry out)")
            raise CliError(f"{folder / name} matches no service of {inst.name}: each entry is "
                           "named as a service's manifest accepts (its `restore` names)")
        svc, restore, is_dir = accepted[name]
        if kind == "file" and is_dir:
            raise CliError(f"{folder / name} must be a directory for {svc.name}")
        if kind == "dir" and not is_dir:
            raise CliError(f"{folder / name} must be a file for {svc.name}")
        if svc.name in chosen:
            raise CliError(f"{folder} has two entries for {svc.name}: {chosen[svc.name].entry} "
                           f"and {name}; keep one")
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
    """The folder --from names, as the host has it: the launcher resolves it (PIHX_FROM) and mounts
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
            # The launcher mounts an existing folder outside them, and says so in PIHX_FROM.
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
    return subprocess.run(["docker", *args], env=env, **kwargs)


def tool_images(inst):
    """The images utils/lib/images.sh names (ALPINE_IMAGE, P7ZIP_IMAGE, PERCONA_IMAGE, ...), which
    the overlays run their tools in."""
    text = (inst.tools / "utils" / "lib" / "images.sh").read_text()
    return dict(re.findall(r"^([A-Z][A-Z0-9_]*_IMAGE)=(\S+)", text, re.MULTILINE))


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
        result = _docker(env, "run", "--rm", "-i", "-e", "ARCHIVE_PASSWORD", "-v",
                         f"{path}:/a/{archive}:ro", images["P7ZIP_IMAGE"], "sh", "-c",
                         f'printf "%s\\n" "${{ARCHIVE_PASSWORD:-}}" | 7z l -slt /a/{archive}')
        if result.returncode != 0:
            return None
        total = sum(int(v) for v in re.findall(r"^Size = (\d+)$", result.stdout, re.MULTILINE))
        return 2 * ((total + 1023) // 1024)
    mode = ("dir" if _is_dir_entry(choice) else
            "gz" if choice.entry.endswith((".gz", ".tgz")) else "file")
    result = _docker(env, "run", "--rm", "-v", f"{path}:/s:ro", images["ALPINE_IMAGE"],
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
        self.compose = compose_module.Compose(inst, extra_files=self.overlays,
                                              extra_env=self.extra)
        self.data = {o: services_module.read_overlay(o) for o in self.overlays}

    def env(self):
        return self.compose.environment()

    def project_volumes(self):
        result = _docker(self.env(), "volume", "ls", "-q", "--filter",
                         f"label=com.docker.compose.project={self.inst.name}")
        return set(result.stdout.split())

    def refuse_existing_volumes(self):
        """Every volume a restore the instance's services declare would write must be new."""
        volumes = set()
        for svc in self.inst.services:
            for overlay in svc.restore_overlays():
                declared, mounted = services_module.overlay_volumes(
                    services_module.read_overlay(overlay))
                volumes |= declared | mounted
        for vol in sorted(volumes):
            full = f"{self.inst.name}_{vol}"
            if _docker(self.env(), "volume", "inspect", full).returncode == 0:
                raise CliError(f"{full} already exists -- initialize only runs against a "
                               "brand-new instance with no existing data. Run "
                               f"'pihx {self.inst.name} destroy' first if you really want to "
                               "start over.")

    def resolve_image_users(self):
        """x-pihx image-user: a variable the instance and the caller leave unset becomes the
        <uid>:<gid> the service's image runs as. Before any volume exists, so an image that can't
        be run fails first."""
        for overlay, data in self.data.items():
            user = data.get(services_module.EXTENSION, {}).get("image-user")
            if not user:
                continue
            variable, service = user["variable"], user["service"]
            if self.config.get(variable) or self.extra.get(variable):
                continue
            config = self.base.run("config", "--format", "json", stdout=subprocess.PIPE,
                                   text=True)
            image = (json.loads(config.stdout).get("services", {}).get(service) or {}).get("image")
            if not image:
                raise CliError(f"{overlay}: x-pihx image-user names {service}, which has no image "
                               f"in {self.inst.name}")
            result = _docker(self.env(), "run", "--rm", "--entrypoint", "sh", image, "-c",
                             'echo "$(id -u):$(id -g)"')
            owner = result.stdout.strip()
            if result.returncode != 0 or not re.fullmatch(r"\d+:\d+", owner):
                sys.stderr.write(result.stderr)
                raise CliError(f"couldn't determine the user {image} runs as -- set "
                               f"{variable}=<uid>:<gid> to choose it explicitly")
            self.extra[variable] = owner

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

    def remove_restore_volumes(self):
        declared = set()
        for data in self.data.values():
            declared |= services_module.overlay_volumes(data)[0]
        names = [f"{self.inst.name}_{v}" for v in sorted(declared)]
        if names:
            _docker(self.env(), "volume", "rm", *names)

    def write_env(self):
        """x-pihx env: written to the restored service's <svc>.env unless it sets them."""
        for choice in self.choices:
            env_file = self.inst.dir / f"{choice.service.name}.env"
            for overlay in choice.overlays():
                values = self.data[overlay].get(services_module.EXTENSION, {}).get("env", {})
                current = envfile.parse(env_file.read_text()) if env_file.is_file() else {}
                lines = [envfile.format_line(k, v) for k, v in values.items() if k not in current]
                if lines:
                    with open(env_file, "a") as f:
                        f.write("".join(line + "\n" for line in lines))
                    note(f"Set {', '.join(k for k in values if k not in current)} in {env_file}")


def _restore(inst, folder):
    choices = choose(inst, folder, _entries(folder))
    if not choices:
        raise CliError(f"{folder} holds nothing to restore for {inst.name}")
    for choice in choices:
        note(f"{choice.service.name}: {choice.entry}")
    restore = Restore(inst, choices)
    restore.refuse_existing_volumes()
    check_space(restore.env(), restore.images, choices)
    restore.resolve_image_users()
    before = restore.project_volumes()
    try:
        restore.run()
        restore.remove_restore_volumes()
    except BaseException as e:
        if isinstance(e, compose_module.ComposeError):
            # `up` failed on a container it waited for, whose output (e.g. 7z's "Wrong password")
            # is the clue; down removes it.
            logs = restore.compose.run("logs", "--tail=20", check=False, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True)
            sys.stderr.write(logs.stdout or "")
        restore.compose.run("down", check=False, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
        restore.remove_restore_volumes()
        made = sorted(restore.project_volumes() - before)
        if made:
            _docker(restore.env(), "volume", "rm", *made)
        if not isinstance(e, Exception):
            raise
        raise CliError(f"initialize failed: {e}. The containers and volumes it made are "
                       "removed.") from None
    restore.write_env()


# --- seed images ----------------------------------------------------------------------------------

def _copy_seed(inst, image, env):
    """Copies <image>'s /seed folder into a new temporary folder under PIHX_HOME (mounted at its
    host path, so the restore containers can mount what's in it). Returns (folder, pulled)."""
    pulled = _docker(env, "image", "inspect", image).returncode != 0
    if pulled:
        note(f"Pulling {image}")
        result = _docker(env, "pull", "-q", image)
        if result.returncode != 0:
            raise CliError(f"couldn't pull {image}: {result.stderr.strip()}")
    folder = Path(tempfile.mkdtemp(prefix=f".{inst.name}-seed-", dir=instance_module.home()))
    try:
        created = _docker(env, "create", image, "none")
        if created.returncode != 0:
            raise CliError(f"couldn't create a container of {image}: {created.stderr.strip()}")
        cid = created.stdout.strip()
        try:
            copied = _docker(env, "cp", f"{cid}:{SEED_DIR}/.", f"{folder}/")
            if copied.returncode != 0:
                raise CliError(f"{image} has no {SEED_DIR} folder to restore from: "
                               f"{copied.stderr.strip()}")
        finally:
            _docker(env, "rm", cid)
    except BaseException:
        shutil.rmtree(folder, ignore_errors=True)
        raise
    return folder, pulled


def cmd_initialize(name, args):
    option, value = _parse_args(name, args)
    inst = instance_module.open(instance_module.home(), name, tools=tools_dir())
    with lock.hold(inst, lock.wait_seconds(), command="initialize"):
        if option == "--from":
            _restore(inst, from_folder(value))
        else:
            env = compose_module.Compose(inst).environment()
            folder, pulled = _copy_seed(inst, value, env)
            try:
                _restore(inst, folder)
            finally:
                shutil.rmtree(folder, ignore_errors=True)
            # A seed is used once: removed if this run pulled it, kept if it was here already
            # (e.g. built locally, and maybe in no registry).
            if pulled and _docker(env, "image", "rm", value).returncode == 0:
                note(f"Removed {value}, pulled for this command")
    print(f"Initialized {name}.")
    return 0
