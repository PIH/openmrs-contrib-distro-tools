"""Services: the directories under <tools>/services, each with a manifest (service.yaml), its compose
file (compose.yaml) and its env defaults (env.defaults), plus optional restore overlays (restore/),
a summary script (summary.sh) and commands (commands/<name>)."""

import dataclasses
import re
from pathlib import Path

import yaml

from pihx import envfile

NAME = re.compile(r"[a-z0-9][a-z0-9_-]*")
# `pihx <instance> <service> <command>` shares its second word with the core's commands, and
# `instance` names instance.env, so no service can take these names.
CORE_COMMANDS = frozenset({
    "list", "help", "version",
    "create", "add-service", "remove-service", "config", "use-tools",
    "start", "stop", "restart", "status", "logs", "update", "pull", "wait", "run-service",
    "backup", "upload-backups", "list-backups", "copy-backup",
    "initialize", "destroy", "summary",
})
RESERVED_NAMES = CORE_COMMANDS | {"instance"}


class _Loader(yaml.SafeLoader):
    """yaml.safe_load, refusing duplicate keys, and with only true/false as booleans (not YAML
    1.1's yes/no/on/off)."""

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f"duplicate key '{key}'", key_node.start_mark)
            seen.add(key)
        return super().construct_mapping(node, deep)


BOOL_TAG = "tag:yaml.org,2002:bool"
_Loader.yaml_implicit_resolvers = {
    first: [(tag, regexp) for tag, regexp in resolvers if tag != BOOL_TAG]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()}
_Loader.add_implicit_resolver(BOOL_TAG, re.compile(r"^(?:true|false)$"), list("tf"))


def parse_yaml(text):
    """A manifest's YAML. Raises ValueError naming the line."""
    try:
        return yaml.load(text, Loader=_Loader)
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        problem = getattr(e, "problem", None) or str(e)
        raise ValueError(f"line {mark.line + 1}: {problem}" if mark else problem) from None


class ServiceError(Exception):
    """A service is missing or its files are invalid; the message names the file."""


@dataclasses.dataclass
class Restore:
    """A restore entry: the folder entries it accepts, the overlay that restores them, and an
    overlay run after it (e.g. an account reset). Overlay paths are relative to the service dir."""
    names: list
    overlay: str
    after: str = None


@dataclasses.dataclass
class Manifest:
    description: str
    requires: list = dataclasses.field(default_factory=list)
    setup: list = dataclasses.field(default_factory=list)
    capture_env: list = dataclasses.field(default_factory=list)
    job: bool = False
    backup: str = None
    restore: list = dataclasses.field(default_factory=list)


@dataclasses.dataclass
class Service:
    name: str
    dir: Path
    manifest: Manifest
    defaults: dict
    compose_file: Path
    restore_dir: Path = None
    summary_script: Path = None
    commands: dict = dataclasses.field(default_factory=dict)
    # with-<other>.yaml: compose additions applied only when the instance also has <other>
    with_files: dict = dataclasses.field(default_factory=dict)

    def restore_overlays(self):
        """Every overlay its restore entries name (each entry's, then its `after`), once each."""
        found = []
        for entry in self.manifest.restore:
            for overlay in filter(None, (entry.overlay, entry.after)):
                if self.dir / overlay not in found:
                    found.append(self.dir / overlay)
        return found

    def restore_volumes(self):
        """The volumes only its restore overlays declare (e.g. a staging volume): no compose file
        of the instance knows them, so `down -v` doesn't remove them."""
        return {v for f in self.restore_overlays() for v in overlay_volumes(read_overlay(f))[0]}


def load(tools, name):
    """The service <name> in the checkout <tools>."""
    tools = Path(tools)
    svc_dir = tools / "services" / name
    if not svc_dir.is_dir():
        raise ServiceError(f"no service '{name}': {svc_dir} doesn't exist")
    if name in RESERVED_NAMES:
        raise ServiceError(f"{svc_dir}: '{name}' is a pihx command or reserved, so it can't name a "
                           "service")
    if not NAME.fullmatch(name):
        raise ServiceError(f"{svc_dir}: invalid service name '{name}': use lowercase letters, "
                           "digits, '-' and '_', starting with a letter or digit")
    manifest_file, compose_file, defaults_file = (
        svc_dir / "service.yaml", svc_dir / "compose.yaml", svc_dir / "env.defaults")
    for f in (manifest_file, compose_file, defaults_file):
        if not f.is_file():
            raise ServiceError(f"{f} is missing")

    try:
        manifest = _manifest(parse_yaml(manifest_file.read_text()))
    except ValueError as e:
        raise ServiceError(f"{manifest_file}: {e}") from None
    for required in manifest.requires:
        if not (tools / "services" / required).is_dir():
            raise ServiceError(f"{manifest_file}: requires '{required}', which isn't a service in "
                               f"{tools / 'services'}")
    for entry in manifest.restore:
        for overlay in filter(None, (entry.overlay, entry.after)):
            if Path(overlay).is_absolute() or ".." in Path(overlay).parts:
                raise ServiceError(f"{manifest_file}: restore overlay {overlay} must be a path "
                                   "inside the service directory")
            if not (svc_dir / overlay).is_file():
                raise ServiceError(f"{manifest_file}: restore overlay {overlay} doesn't exist")
            read_overlay(svc_dir / overlay)
    try:
        defaults = envfile.parse(defaults_file.read_text())
    except ValueError as e:
        raise ServiceError(f"{defaults_file}: {e}") from None

    commands_dir = svc_dir / "commands"
    commands = {f.name: f for f in sorted(commands_dir.iterdir()) if f.is_file()} \
        if commands_dir.is_dir() else {}
    with_files = {}
    for f in sorted(svc_dir.glob("with-*.yaml")):
        other = f.name[len("with-"):-len(".yaml")]
        if other == name or not (tools / "services" / other).is_dir():
            raise ServiceError(f"{f}: '{other}' isn't another service in {tools / 'services'}")
        with_files[other] = f
    return Service(
        name=name,
        dir=svc_dir,
        manifest=manifest,
        defaults=defaults,
        compose_file=compose_file,
        restore_dir=svc_dir / "restore" if (svc_dir / "restore").is_dir() else None,
        summary_script=svc_dir / "summary.sh" if (svc_dir / "summary.sh").is_file() else None,
        commands=commands,
        with_files=with_files,
    )


# --- restore overlays ---------------------------------------------------------------------------
#
# A restore overlay is a compose file added for `initialize` only. A service may also have
# restore/prepare (run before the restore; prints KEY=value lines for that run only) and
# restore/finish (run after it succeeds), found by their presence.

VOLUME_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


def read_overlay(path):
    """A restore overlay, parsed. Raises ServiceError naming the file."""
    try:
        data = parse_yaml(Path(path).read_text())
        data = {} if data is None else data
        if not isinstance(data, dict):
            raise ValueError("expected a mapping (a compose file)")
    except ValueError as e:
        raise ServiceError(f"{path}: {e}") from None
    return data


def overlay_volumes(data):
    """(the volumes an overlay declares at the top level, the named volumes its containers mount)."""
    declared = set((data.get("volumes") or {}).keys())
    mounted = set()
    for spec in (data.get("services") or {}).values():
        for volume in (spec or {}).get("volumes", []) or []:
            source = volume.split(":")[0] if isinstance(volume, str) else volume.get("source", "")
            if isinstance(volume, dict) and volume.get("type", "volume") != "volume":
                continue
            if VOLUME_NAME.fullmatch(source or ""):
                mounted.add(source)
    return declared, mounted


def all(tools):
    """Every service in the checkout <tools>, by name."""
    services_dir = Path(tools) / "services"
    if not services_dir.is_dir():
        return {}
    return {d.name: load(tools, d.name) for d in sorted(services_dir.iterdir()) if d.is_dir()}


def _manifest(data):
    if not isinstance(data, dict):
        raise ValueError("expected a mapping of manifest fields")
    fields = {"description", "requires", "setup", "capture-env", "job", "backup", "restore"}
    for key in data:
        if key not in fields:
            raise ValueError(f"unknown key '{key}' (known: {', '.join(sorted(fields))})")
    if not isinstance(data.get("description"), str) or not data["description"]:
        raise ValueError("'description' is required")
    if not isinstance(data.get("job", False), bool):
        raise ValueError("'job' must be true or false")
    if data.get("backup", "none") != "none":
        raise ValueError("'backup' can only be 'none' (backups come with TASKS-597)")
    restore = data.get("restore", [])
    if not isinstance(restore, list):
        raise ValueError("'restore' must be a list")
    return Manifest(
        description=data["description"],
        requires=_strings(data, "requires"),
        setup=_strings(data, "setup"),
        capture_env=_strings(data, "capture-env"),
        job=data.get("job", False),
        backup=data.get("backup"),
        restore=[_restore(entry) for entry in restore],
    )


def _strings(data, key):
    value = data.get(key, [])
    # (`all` is this module's.)
    if not isinstance(value, list) or any(not isinstance(v, str) or not v for v in value):
        raise ValueError(f"'{key}' must be a list of names")
    return value


def _restore(entry):
    if not isinstance(entry, dict):
        raise ValueError("each 'restore' entry must be a mapping with 'names' and 'overlay'")
    for key in entry:
        if key not in ("names", "overlay", "after"):
            raise ValueError(f"unknown key '{key}' in a 'restore' entry (known: after, names, "
                             "overlay)")
    names = _strings(entry, "names")
    if not names:
        raise ValueError("a 'restore' entry needs 'names', the folder entries it accepts")
    if not isinstance(entry.get("overlay"), str):
        raise ValueError("a 'restore' entry needs 'overlay', the file that restores it")
    if not isinstance(entry.get("after", ""), str):
        raise ValueError("a 'restore' entry's 'after' must be a file name")
    return Restore(names=names, overlay=entry["overlay"], after=entry.get("after"))
