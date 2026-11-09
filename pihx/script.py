"""Running a service's scripts (restore hooks, summary.sh, commands/*) in pihx's container.

A script's environment is the instance's merged values, then what Compose runs with: PIHX_INSTANCE,
PIHX_INSTANCE_DIR, PIHX_TOOLS, PIHX_HOME, PIHX_SERVICE (the script's own service), SERVICE_NAME (the
instance's name, as compose files interpolate it) and COMPOSE_PROJECT_NAME, COMPOSE_FILE and
COMPOSE_ENV_FILES, so a plain `docker compose ...` targets the instance, and PYTHONPATH (the tools
directory) with PYTHONDONTWRITEBYTECODE, so a script can run `python3 -m pihx...` from anywhere.
Compose 2.40 has no environment variable for the project directory, so a
script that runs Compose passes `--project-directory "$PIHX_INSTANCE_DIR"` itself (relative paths in
the compose files resolve against it).

The environment holds the instance's secrets: scripts must not print it (no `env`, `set -x`)."""

import subprocess

from pihx import compose as compose_module
from pihx.commands import CliError


def environment(inst, extra_env=None, service=None, extra_files=()):
    """The environment for a script of <inst> (of <service>, named in PIHX_SERVICE); <extra_env>
    (e.g. a restore's values) wins, and <extra_files> are in its COMPOSE_FILE."""
    compose = compose_module.Compose(inst, extra_files=extra_files, extra_env=extra_env)
    env = {**inst.config(), **compose.environment()}
    own = {"PIHX_SERVICE": service.name} if service else {}
    # PIHX_HOME and PYTHONPATH, so a script can run pihx itself (see lifecycle._start) or one of its
    # modules (python3 -m pihx.envfile); no bytecode, since the tools directory may be read-only.
    own["PIHX_HOME"] = str(inst.dir.parent)
    own["PYTHONPATH"] = env["PIHX_TOOLS"]
    own["PYTHONDONTWRITEBYTECODE"] = "1"
    return {**env, **own}


def run(inst, path, args=(), extra_env=None, service=None, label=None, extra_files=(), **kwargs):
    """Runs <path> with <args> in environment(inst, extra_env, service, extra_files); kwargs go to
    subprocess.run (output isn't captured unless they say so). Returns the CompletedProcess; raises
    CliError if the script can't be started (<label> names it in the message, default its path)."""
    try:
        return subprocess.run([str(path), *args],
                              env=environment(inst, extra_env, service, extra_files),
                              **kwargs)
    except OSError as e:
        raise CliError(f"{label or path} couldn't run: {e.strerror or type(e).__name__}") from None
