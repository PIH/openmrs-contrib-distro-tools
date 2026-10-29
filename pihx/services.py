"""Services: the directories under <tools>/services, each with a manifest (service.yaml), its compose
file (compose.yaml) and its env defaults (env.defaults), plus optional restore overlays (restore/),
a summary script (summary.sh) and commands (commands/<name>)."""

import dataclasses
import re
from pathlib import Path

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
            if not (svc_dir / overlay).is_file():
                raise ServiceError(f"{manifest_file}: restore overlay {overlay} doesn't exist")
    try:
        defaults = envfile.parse(defaults_file.read_text())
    except ValueError as e:
        raise ServiceError(f"{defaults_file}: {e}") from None

    commands_dir = svc_dir / "commands"
    commands = {f.name: f for f in sorted(commands_dir.iterdir()) if f.is_file()} \
        if commands_dir.is_dir() else {}
    return Service(
        name=name,
        dir=svc_dir,
        manifest=manifest,
        defaults=defaults,
        compose_file=compose_file,
        restore_dir=svc_dir / "restore" if (svc_dir / "restore").is_dir() else None,
        summary_script=svc_dir / "summary.sh" if (svc_dir / "summary.sh").is_file() else None,
        commands=commands,
    )


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


# The manifest's YAML: the subset manifests need, since pihx uses only Python's standard library.
# Block mappings and sequences, flow sequences of scalars, plain and quoted scalars, true/false,
# null/~ and comments. Anything else (flow mappings, anchors, tags, block scalars, escapes, tabs,
# duplicate keys) is refused rather than read differently from YAML.

KEY = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_.-]*):(?:\s+(.*))?")
PLAIN_REFUSED = tuple("{}[]&*!|>%@`,")


def parse_yaml(text):
    """The manifest YAML <text> as dicts, lists, strings, booleans and None. Raises ValueError
    naming the line."""
    lines = []
    for number, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw[:len(raw) - len(raw.lstrip())]:
            raise ValueError(f"line {number}: tab in indentation")
        content = _strip_comment(raw).rstrip()
        if content.strip():
            lines.append((number, len(content) - len(content.lstrip()), content.strip()))
    if not lines:
        return None
    parser = _Parser(lines)
    value = parser.node(lines[0][1])
    if parser.i < len(lines):
        parser.fail("unexpected indentation")
    return value


def _strip_comment(line):
    quote, i = None, -1
    while i + 1 < len(line):
        i += 1
        c = line[i]
        if quote:
            if c == quote == "'" and line[i + 1:i + 2] == "'":
                i += 1  # '' is a quote inside a single-quoted string
            elif c == quote:
                quote = None
        elif c in "'\"" and (i == 0 or line[i - 1] in " \t[,:-"):
            quote = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


class _Parser:
    def __init__(self, lines):
        self.lines, self.i = lines, 0

    def fail(self, message):
        number = self.lines[min(self.i, len(self.lines) - 1)][0]
        raise ValueError(f"line {number}: {message}")

    def peek(self):
        return self.lines[self.i] if self.i < len(self.lines) else None

    def node(self, indent):
        _, _, content = self.peek()
        if content == "-" or content.startswith("- "):
            return self.sequence(indent)
        return self.mapping(indent)

    def mapping(self, indent, first=None):
        result = {}
        while True:
            line = first or self.peek()
            if line is None or line[1] < indent:
                return result
            number, line_indent, content = line
            if line_indent > indent or content == "-" or content.startswith("- "):
                self.fail("unexpected indentation" if line_indent > indent else "expected 'key:'")
            match = KEY.fullmatch(content)
            if not match:
                self.fail("expected 'key: value'")
            key, rest = match.group(1), match.group(2)
            if key in result:
                self.fail(f"duplicate key '{key}'")
            if not first:
                self.i += 1
            first = None
            if rest:
                result[key] = self.scalar_or_flow(rest)
            else:
                following = self.peek()
                if following and (following[1] > indent or (following[1] == indent and (
                        following[2] == "-" or following[2].startswith("- ")))):
                    result[key] = self.node(following[1])
                else:
                    result[key] = None

    def sequence(self, indent):
        result = []
        while True:
            line = self.peek()
            if line is None or line[1] < indent:
                return result
            number, line_indent, content = line
            if line_indent > indent:
                self.fail("unexpected indentation")
            if not (content == "-" or content.startswith("- ")):
                return result
            self.i += 1
            item = content[1:].lstrip()
            if not item:
                following = self.peek()
                result.append(self.node(following[1]) if following and following[1] > indent
                              else None)
            elif KEY.fullmatch(item):
                # "- key: value" starts a mapping whose keys line up with this first one.
                item_indent = line_indent + len(content) - len(item)
                result.append(self.mapping(item_indent, first=(number, item_indent, item)))
            else:
                result.append(self.scalar_or_flow(item))

    def scalar_or_flow(self, text):
        if text.startswith("["):
            if not text.endswith("]"):
                self.fail("unterminated '['")
            inner = text[1:-1].strip()
            if not inner:
                return []
            items = [item.strip() for item in _split_flow(inner)]
            if any(not item or item.startswith("[") for item in items):
                self.fail("a flow sequence can hold only scalars")
            return [self.scalar(item) for item in items]
        return self.scalar(text)

    def scalar(self, text):
        if text[0] == "'":
            if len(text) < 2 or not text.endswith("'") or "'" in text[1:-1].replace("''", ""):
                self.fail("bad single-quoted string")
            return text[1:-1].replace("''", "'")
        if text[0] == '"':
            if len(text) < 2 or not text.endswith('"') or '"' in text[1:-1] or "\\" in text:
                self.fail("bad double-quoted string (escapes aren't supported)")
            return text[1:-1]
        if text.startswith(PLAIN_REFUSED) or ": " in text:
            self.fail(f"unsupported YAML: {text} (quote it)")
        return {"true": True, "false": False, "null": None, "~": None}.get(text, text)


def _split_flow(text):
    items, quote, start = [], None, 0
    for i, c in enumerate(text):
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == ",":
            items.append(text[start:i])
            start = i + 1
    items.append(text[start:])
    return items
