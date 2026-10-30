"""Instances: a directory under PIHX_HOME holding instance.env, one <svc>.env per service (its
presence makes the service part of the instance), optional <svc>.override.yaml, .lock, and tools,
the tools directory the instance runs."""

import dataclasses
import os
import re
from pathlib import Path

from pihx import compose, envfile, services as services_module

INSTANCE_ENV = "instance.env"
INSTANCE_DEFAULTS = "instance.env.defaults"
# Global commands come first on the command line, so no instance can take their names.
RESERVED_NAMES = frozenset({"list", "help", "version"})
INSTANCE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]*")


def instance_name_error(name):
    """Why <name> can't be an instance name, or None if it can."""
    if name in RESERVED_NAMES:
        return f"'{name}' is a pihx command, so it can't name an instance"
    if not INSTANCE_NAME.fullmatch(name):
        return (f"invalid instance name '{name}': it must be lowercase letters, digits, '-' and "
                "'_', starting with a letter or digit")
    return None


class InstanceError(Exception):
    """An instance is missing or its files are invalid; the message names the file. A usage error
    (e.g. no such instance) exits 2."""

    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


@dataclasses.dataclass
class Instance:
    name: str
    dir: Path
    tools: Path
    services: list

    def env_files(self):
        """The env files whose values the instance sees, later ones winning: the tools directory's
        instance.env.defaults, every service's defaults, then every <svc>.env, then instance.env
        (if present)."""
        files = []
        if (self.tools / INSTANCE_DEFAULTS).is_file():
            files.append(self.tools / INSTANCE_DEFAULTS)
        files += [s.dir / "env.defaults" for s in self.services]
        files += [self.dir / f"{s.name}.env" for s in self.services]
        if (self.dir / INSTANCE_ENV).is_file():
            files.append(self.dir / INSTANCE_ENV)
        return files

    def config(self):
        """The instance's merged values, as Compose's interpolation sees them: env files read in
        order with `$` references expanded, in the environment pihx runs Compose with."""
        try:
            return envfile.merge(self.env_files(), compose.environment(self))
        except ValueError as e:
            raise InstanceError(str(e)) from None


def open(home, name, tools=None):
    """The instance <name> under <home>. <tools> is the tools directory it runs: by default PIHX_TOOLS,
    since the launcher has already handed off to the instance's own tools directory (resolved on the
    host, not here)."""
    error = instance_name_error(name)
    if error:
        raise InstanceError(error)
    instance_dir = Path(home).absolute() / name
    if not instance_dir.is_dir():
        raise InstanceError(f"no instance '{name}': {instance_dir} doesn't exist", status=2)
    if tools is None:
        tools = os.environ.get("PIHX_TOOLS")
        if not tools:
            raise InstanceError("PIHX_TOOLS isn't set (run pihx through bin/pihx)")
    # Not resolved: the host may resolve it differently.
    tools = Path(tools).absolute()
    found = []
    for env_file in sorted(instance_dir.glob("*.env")):
        # A dotfile (e.g. `.env`) is no service's: Python's glob matches it, unlike a shell's.
        if env_file.name == INSTANCE_ENV or env_file.name.startswith("."):
            continue
        svc = env_file.name[:-len(".env")]
        if not (tools / "services" / svc).is_dir():
            raise InstanceError(f"{env_file}: there's no service '{svc}' in {tools / 'services'}")
        try:
            found.append(services_module.load(tools, svc))
        except services_module.ServiceError as e:
            raise InstanceError(f"{env_file}: {e}") from None
    _refuse_start_values(instance_dir, found)
    return Instance(name=name, dir=instance_dir, tools=tools, services=found)


def _refuse_start_values(instance_dir, services):
    """A variable a service's start-env script sets (e.g. OPENMRS_DB_FOUND_EMPTY) is decided at
    each start: in an env file it would stand in whenever the script gives none, or for a plain
    `docker compose up`. A file that can't be parsed is left for config() to report."""
    owners = {name: (svc, entry.script) for svc in services for entry in svc.manifest.start_env
              for name in entry.sets}
    if not owners:
        return
    for env_file in sorted(instance_dir.glob("*.env")):
        if env_file.name.startswith("."):
            continue
        try:
            names = envfile.parse(env_file.read_text())
        except (OSError, ValueError):
            continue
        for name in sorted(set(names) & set(owners)):
            svc, script = owners[name]
            raise InstanceError(f"{env_file}: {name} can't be set in a file: {svc.name}'s "
                                f"{script} decides it at each start. Remove it from the file.")


def home():
    """PIHX_HOME, the directory holding the instances (default ~/pihx)."""
    return Path(os.environ.get("PIHX_HOME") or Path.home() / "pihx").absolute()
