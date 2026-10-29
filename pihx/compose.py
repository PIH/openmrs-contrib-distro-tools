"""Docker Compose on an instance: its project, env files and compose files."""

import os
import subprocess


# All Compose (and later, service scripts) get from the caller's environment: anything else would
# beat the instance's env files in Compose's interpolation.
PASSED_THROUGH = ("PATH", "HOME", "DOCKER_CONFIG", "DOCKER_HOST")


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
        """docker compose's options for the instance, in override order. Relative paths in compose
        files resolve against the instance directory."""
        args = ["-p", self.instance.name, "--project-directory", str(self.instance.dir)]
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

    def environment(self):
        """The whole environment to run Compose (or a service script) with: env() plus only
        PASSED_THROUGH from the caller's."""
        passed = {name: os.environ[name] for name in PASSED_THROUGH if name in os.environ}
        return {**passed, **self.env()}

    def run(self, *args, check=True, **kwargs):
        """Runs `docker compose <options> <args>` in environment(); kwargs go to subprocess.run.
        With check, a failure raises ComposeError."""
        result = subprocess.run(["docker", "compose", *self.args(), *args],
                                env=self.environment(), **kwargs)
        if check and result.returncode != 0:
            raise ComposeError(f"docker compose {' '.join(args)} failed (exit {result.returncode})")
        return result


def environment(instance, extra_files=()):
    """Compose(instance, extra_files).environment()."""
    return Compose(instance, extra_files).environment()
