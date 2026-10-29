"""Instances: a directory under PIHX_HOME holding instance.env, one <svc>.env per service (its
presence makes the service part of the instance), optional <svc>.override.yaml, .lock, and tools,
the checkout the instance runs."""

import dataclasses
import os
from pathlib import Path

from pihx import envfile, services as services_module

INSTANCE_ENV = "instance.env"


class InstanceError(Exception):
    """An instance is missing or its files are invalid; the message names the file."""


@dataclasses.dataclass
class Instance:
    name: str
    dir: Path
    tools: Path
    services: list

    def env_files(self):
        """The env files whose values the instance sees, later ones winning: every service's
        defaults, then every <svc>.env, then instance.env (if present)."""
        files = [s.dir / "env.defaults" for s in self.services]
        files += [self.dir / f"{s.name}.env" for s in self.services]
        if (self.dir / INSTANCE_ENV).is_file():
            files.append(self.dir / INSTANCE_ENV)
        return files

    def config(self):
        """The instance's merged values, as Compose interpolation sees them."""
        merged = {}
        for f in self.env_files():
            try:
                merged.update(envfile.parse(f.read_text()))
            except (OSError, ValueError) as e:
                raise InstanceError(f"{f}: {e}") from None
        return merged


def open(home, name, tools=None):
    """The instance <name> under <home>. <tools> is the checkout it runs: by default PIHX_TOOLS,
    since the launcher has already handed off to the instance's own checkout (its tools link is
    resolved on the host, not here)."""
    instance_dir = Path(home) / name
    if not instance_dir.is_dir():
        raise InstanceError(f"no instance '{name}': {instance_dir} doesn't exist")
    if tools is None:
        tools = os.environ.get("PIHX_TOOLS") or Path(__file__).resolve().parent.parent
    tools = Path(tools)
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
