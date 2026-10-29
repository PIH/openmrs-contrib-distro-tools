"""Docker Compose on an instance: its project, env files and compose files."""

import os
import subprocess


class ComposeError(Exception):
    """A docker compose command failed (Compose has already printed why)."""


class Compose:
    def __init__(self, instance, extra_files=()):
        self.instance = instance
        self.extra_files = list(extra_files)

    def env_files(self):
        return self.instance.env_files()

    def compose_files(self):
        """Each service's compose.yaml followed by its <svc>.override.yaml (if present), then the
        extra files (e.g. a restore overlay)."""
        files = []
        for svc in self.instance.services:
            files.append(svc.compose_file)
            override = self.instance.dir / f"{svc.name}.override.yaml"
            if override.is_file():
                files.append(override)
        return files + self.extra_files

    def args(self):
        """docker compose's options for the instance, in override order."""
        args = ["-p", self.instance.name]
        for f in self.env_files():
            args += ["--env-file", str(f)]
        for f in self.compose_files():
            args += ["-f", str(f)]
        return args

    def env(self):
        """The variables compose files interpolate, plus COMPOSE_* so a plain `docker compose` in a
        service script or command targets the instance the same way."""
        return {
            "COMPOSE_PROJECT_NAME": self.instance.name,
            "COMPOSE_FILE": os.pathsep.join(str(f) for f in self.compose_files()),
            "COMPOSE_ENV_FILES": ",".join(str(f) for f in self.env_files()),
            "SERVICE_NAME": self.instance.name,
            "PIHX_TOOLS": str(self.instance.tools),
            "PIHX_INSTANCE_DIR": str(self.instance.dir),
            "PIHX_INSTANCE": self.instance.name,
        }

    def run(self, *args, check=True, **kwargs):
        """Runs `docker compose <options> <args>`; kwargs go to subprocess.run. With check, a
        failure raises ComposeError."""
        result = subprocess.run(["docker", "compose", *self.args(), *args],
                                env={**os.environ, **self.env()}, **kwargs)
        if check and result.returncode != 0:
            raise ComposeError(f"docker compose {' '.join(args)} failed (exit {result.returncode})")
        return result
