"""Instances: a directory under PIHX_HOME holding instance.env, one <svc>.env per service (its
presence makes the service part of the instance), optional <svc>.override.yaml, .lock, and tools,
the checkout the instance runs."""

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
        return (f"invalid instance name '{name}': use lowercase letters, digits, '-' and '_', "
                "starting with a letter or digit")
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
        """The env files whose values the instance sees, later ones winning: the checkout's
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
    """The instance <name> under <home>. <tools> is the checkout it runs: by default PIHX_TOOLS,
    since the launcher has already handed off to the instance's own checkout (its tools link is
    resolved on the host, not here)."""
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
    # Not resolved: tools may be a link the host resolves.
    tools = Path(tools).absolute()
    found = []
    for env_file in sorted(instance_dir.glob("*.env")):
        if env_file.name == INSTANCE_ENV:
            continue
        svc = env_file.name[:-len(".env")]
        if not (tools / "services" / svc).is_dir():
            raise InstanceError(f"{env_file}: there's no service '{svc}' in {tools / 'services'}")
        try:
            found.append(services_module.load(tools, svc))
        except services_module.ServiceError as e:
            raise InstanceError(f"{env_file}: {e}") from None
    return Instance(name=name, dir=instance_dir, tools=tools, services=found)


def home():
    """PIHX_HOME, the directory holding the instances (default ~/pihx)."""
    return Path(os.environ.get("PIHX_HOME") or Path.home() / "pihx").absolute()
