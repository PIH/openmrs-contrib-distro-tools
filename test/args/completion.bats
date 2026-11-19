#!/usr/bin/env bats
# completion/pihx.bash: what Tab offers at each position, from a made-up PIHX_HOME (it reads only
# the filesystem), and that its command lists match pihx's and openmrs-docker's.

load ../helpers

setup() {
    export PIHX_HOME="$BATS_TEST_TMPDIR/home"
    TOOLS="$BATS_TEST_TMPDIR/tools"
    mkdir -p "$TOOLS/services/openmrs-db/commands" "$TOOLS/services/openmrs" "$TOOLS/services/petl"
    touch "$TOOLS/services/openmrs-db/commands/reset-accounts"
    # Two instances, an archive (a copy of an instance's env files, not an instance) and a stray
    # directory.
    mkdir -p "$PIHX_HOME/alpha" "$PIHX_HOME/beta" "$PIHX_HOME/alpha.archive-20261118" "$PIHX_HOME/stray"
    touch "$PIHX_HOME/alpha/instance.env" "$PIHX_HOME/alpha/openmrs-db.env" \
        "$PIHX_HOME/alpha/openmrs.env" "$PIHX_HOME/beta/instance.env" \
        "$PIHX_HOME/alpha.archive-20261118/instance.env"
    ln -s "$TOOLS" "$PIHX_HOME/alpha/tools"
    mkdir -p "$BATS_TEST_TMPDIR/dirs/seed" "$BATS_TEST_TMPDIR/dirs/somewhere"
    # shellcheck source=../../completion/pihx.bash
    . "$REPO_ROOT/completion/pihx.bash"
}

# Prints, sorted and on one line, what Tab offers for the command line <words...>, the last being
# the word under the cursor ('' for a new one).
offers() { # <words...>
    COMP_WORDS=("$@")
    COMP_CWORD=$(($# - 1))
    _pihx_complete
    printf '%s\n' "${COMPREPLY[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

@test "both commands are registered" {
    run complete -p pihx openmrs-docker
    assert_success
    assert_line "complete -F _pihx_complete pihx"
    assert_line "complete -F _pihx_complete openmrs-docker"
}

@test "the first word is an instance or a global command" {
    run offers pihx ''
    assert_output "alpha beta help list version"
    run offers pihx a
    assert_output "alpha"
    run offers pihx list ''
    assert_output ""
}

@test "after an instance: its commands and its services" {
    run offers pihx alpha ''
    assert_output --partial "add-service"
    assert_output --partial "openmrs-db"
    refute_output --partial "build"
    refute_output --partial "_start"
    run offers pihx alpha openm
    assert_output "openmrs openmrs-db"
    run offers openmrs-docker alpha bu
    assert_output "build"
    # An instance not made yet (create) still gets the commands.
    run offers pihx gamma cr
    assert_output "create"
}

@test "a service's commands" {
    run offers pihx alpha openmrs-db ''
    assert_output "reset-accounts"
    run offers pihx alpha openmrs ''
    assert_output ""
    run offers pihx alpha openmrs-db reset-accounts ''
    assert_output ""
}

@test "add-service offers the services the instance doesn't have; logs and remove-service, those it has" {
    run offers pihx alpha add-service ''
    assert_output "petl"
    run offers pihx alpha logs ''
    assert_output "openmrs openmrs-db"
    run offers pihx alpha remove-service openmrs-
    assert_output "openmrs-db"
    run offers pihx alpha logs openmrs ''
    assert_output ""
}

@test "compose offers its allowed subcommands only" {
    run offers pihx alpha compose ''
    assert_output "config events exec images logs ls port ps top version"
    run offers pihx alpha compose u
    assert_output ""
}

@test "use-tools, initialize --from and archive --to offer directories" {
    cd "$BATS_TEST_TMPDIR/dirs"
    run offers pihx alpha use-tools s
    assert_output "seed somewhere"
    run offers pihx alpha initialize --from se
    assert_output "seed"
    run offers pihx alpha initialize --from = se
    assert_output "seed"
    run offers pihx alpha archive --to = so
    assert_output "somewhere"
}

@test "options" {
    run offers pihx alpha initialize --
    assert_output "--from --from-image --pull"
    run offers pihx alpha initialize --from-image ''
    assert_output ""
    run offers pihx alpha config ''
    assert_output "--show-secrets"
    run offers pihx alpha start --
    assert_output ""
    run offers openmrs-docker alpha start --
    assert_output "--build --dev"
    run offers openmrs-docker alpha update --dev --
    assert_output "--build --dev"
}

@test "create --services= offers this checkout's services, as a comma-separated list" {
    run offers pihx gamma create --services = ''
    assert_output --partial "openmrs-db"
    assert_output --partial "petl"
    run offers pihx gamma create --services = openmrs-db,pe
    assert_output "openmrs-db,petl"
    run offers pihx gamma create --services = openmrs-db,openmrs-d
    assert_output ""
}

@test "the command lists match pihx's and openmrs-docker's" {
    run runtime_python - "$(. "$REPO_ROOT/completion/pihx.bash"
        echo "$_PIHX_INSTANCE_COMMANDS" "| $_PIHX_OPENMRS_DOCKER_COMMANDS | $_PIHX_COMPOSE_SUBCOMMANDS")" <<'PYTHON'
import sys
from pihx import cli
from pihx.commands import lifecycle
from openmrs import extension
instance, openmrs, compose = (set(part.split()) for part in sys.argv[1].split("|"))
public = lambda names: {n for n in names if not n.startswith("_")}
problems = []
if instance != public(cli.INSTANCE_COMMANDS) | {"help"}:
    problems.append(f"instance commands: {sorted(instance ^ (public(cli.INSTANCE_COMMANDS) | {'help'}))}")
if openmrs != public(extension.COMMANDS) - set(cli.INSTANCE_COMMANDS):
    problems.append(f"openmrs-docker commands: {sorted(openmrs ^ (public(extension.COMMANDS) - set(cli.INSTANCE_COMMANDS)))}")
if compose != set(lifecycle.COMPOSE_INSPECT):
    problems.append(f"compose subcommands: {sorted(compose ^ set(lifecycle.COMPOSE_INSPECT))}")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PYTHON
    assert_success
    assert_output ""
}
