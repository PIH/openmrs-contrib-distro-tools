"""Running a service's scripts (restore hooks, summary.sh, commands/*) in pihx's container.

A script's environment is the instance's merged values, then what Compose runs with: PIHX_INSTANCE,
PIHX_INSTANCE_DIR, PIHX_TOOLS, PIHX_HOME, PIHX_SERVICE (the script's own service), SERVICE_NAME (the
instance's name, as compose files interpolate it) and COMPOSE_PROJECT_NAME, COMPOSE_FILE and
COMPOSE_ENV_FILES, so a plain `docker compose ...` targets the instance. Compose 2.40 has no environment variable for the project directory, so a
script that runs Compose passes `--project-directory "$PIHX_INSTANCE_DIR"` itself (relative paths in
the compose files resolve against it).

The environment holds the instance's secrets: scripts must not print it (no `env`, `set -x`)."""

import subprocess

from pihx import compose as compose_module
from pihx.commands import CliError


def environment(inst, extra_env=None, service=None):
    """The environment for a script of <inst> (of <service>, named in PIHX_SERVICE); <extra_env>
    (e.g. a restore's values) wins."""
    compose = compose_module.Compose(inst, extra_env=extra_env)
    own = {"PIHX_SERVICE": service.name} if service else {}
    # PIHX_HOME, so a script can run pihx itself (see lifecycle._start).
    own["PIHX_HOME"] = str(inst.dir.parent)
    return {**inst.config(), **compose.environment(), **own}


def run(inst, path, args=(), extra_env=None, service=None, label=None, **kwargs):
    """Runs <path> with <args> in environment(inst, extra_env, service); kwargs go to
    subprocess.run (output isn't captured unless they say so). Returns the CompletedProcess; raises
    CliError if the script can't be started (<label> names it in the message, default its path)."""
    try:
        return subprocess.run([str(path), *args], env=environment(inst, extra_env, service),
                              **kwargs)
    except OSError as e:
        raise CliError(f"{label or path} couldn't run: {e.strerror or type(e).__name__}") from None
