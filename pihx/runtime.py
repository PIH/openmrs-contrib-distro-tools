"""Setting up the pihx-runtime container before pihx runs any docker command."""

import json
import os


class SetupError(Exception):
    """The container can't be set up for pihx."""


# Credential helpers run binaries (docker-credential-*) that pihx-runtime doesn't have; with them
# left in, every pull fails. Credentials stored inline (auths) still work.
CREDENTIAL_HELPER_KEYS = ("credsStore", "credHelpers")


def install_docker_config(source, home):
    """Copies the caller's Docker config <source> to <home>/.docker/config.json without its
    credential helpers. The copy, not a mount, so <home>/.docker stays writable (buildx)."""
    try:
        with open(source) as f:
            config = json.load(f)
    except (OSError, ValueError) as e:
        # Only the kind of error: a parse error's message can quote the file, credentials included.
        raise SetupError(f"can't read the Docker config {source}: {type(e).__name__}") from None
    if not isinstance(config, dict):
        raise SetupError(f"the Docker config {source} isn't a JSON object")
    for key in CREDENTIAL_HELPER_KEYS:
        config.pop(key, None)
    target_dir = os.path.join(home, ".docker")
    os.makedirs(target_dir, mode=0o700, exist_ok=True)
    target = os.path.join(target_dir, "config.json")
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(config, f)
