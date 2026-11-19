# Tab completion for pihx and openmrs-docker, in bash (and zsh, through bashcompinit). Load it from
# ~/.bashrc:
#   . <tools directory>/completion/pihx.bash
#
# Candidates come from the filesystem only: instances are the directories in PIHX_HOME (default
# ~/pihx) with an instance.env, an instance's services are its <svc>.env files, and a service's
# commands are the files in <instance>/tools/services/<svc>/commands/. It never runs pihx, since
# every pihx run starts a container, which would make each Tab slow.
#
# The command lists below copy pihx/cli.py's INSTANCE_COMMANDS, openmrs/extension.py's COMMANDS
# and lifecycle.py's COMPOSE_INSPECT; test/args/completion.bats fails when they drift apart.

_PIHX_GLOBAL_COMMANDS="list help version"
_PIHX_INSTANCE_COMMANDS="create config add-service remove-service use-tools start stop restart
status logs compose pull update run-service wait summary initialize archive destroy help version"
_PIHX_OPENMRS_DOCKER_COMMANDS="build"
_PIHX_COMPOSE_SUBCOMMANDS="config ps images top port logs events ls version exec"

# The tools directory this file is in, for create --services= (there's no instance yet to ask).
# $0 is the sourced file's path in zsh.
_PIHX_COMPLETION_TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)

# Prints the instances in PIHX_HOME, one per line: directories with an instance.env, named as pihx
# allows (so an archive's copy, <instance>.archive-<time>, isn't one).
_pihx_instances() {
    local home=${PIHX_HOME:-$HOME/pihx} dir name
    for dir in "$home"/*/; do
        name=${dir%/}
        name=${name##*/}
        [[ -f $dir/instance.env && $name =~ ^[a-z0-9][a-z0-9_-]*$ ]] && echo "$name"
    done
}

# Prints instance <name>'s services, one per line: its <svc>.env files, except instance.env.
_pihx_instance_services() { # <name>
    local home=${PIHX_HOME:-$HOME/pihx} file svc
    for file in "$home/$1"/*.env; do
        [[ -f $file ]] || continue
        svc=${file##*/}
        svc=${svc%.env}
        [[ $svc != instance ]] && echo "$svc"
    done
}

# Prints the services in tools directory <tools>, one per line.
_pihx_tools_services() { # <tools>
    local dir
    for dir in "$1/services"/*/; do
        [[ -d $dir ]] || continue
        dir=${dir%/}
        echo "${dir##*/}"
    done
}

# Prints service <svc>'s commands, as instance <name>'s tools directory has them, one per line.
_pihx_service_commands() { # <name> <svc>
    local home=${PIHX_HOME:-$HOME/pihx} file
    for file in "$home/$1/tools/services/$2/commands"/*; do
        [[ -f $file ]] && echo "${file##*/}"
    done
}

# Sets COMPREPLY to the words in <words> that start with <cur>. Words are names, none with a space.
_pihx_reply() { # <words> <cur>
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$1" -- "$2"))
}

# Sets COMPREPLY to the directories that start with <cur>.
_pihx_reply_dirs() { # <cur>
    local IFS=$'\n'
    # shellcheck disable=SC2207 # one directory per line
    COMPREPLY=($(compgen -d -- "$1"))
    # Adds the trailing slash and quoting a path needs. zsh's bashcompinit may not have compopt.
    type compopt &>/dev/null && compopt -o filenames 2>/dev/null
    return 0
}

# No space after the one candidate, when it is to be continued (an option's `=`, a list's `,`).
_pihx_nospace() {
    type compopt &>/dev/null && compopt -o nospace 2>/dev/null
    return 0
}

# The completion function for both commands: COMP_WORDS[0] says which.
_pihx_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    local prev=${COMP_WORDS[COMP_CWORD-1]}
    local cmd=${COMP_WORDS[0]##*/}
    local name=${COMP_WORDS[1]-} command=${COMP_WORDS[2]-}
    local home=${PIHX_HOME:-$HOME/pihx}
    COMPREPLY=()

    # pihx <instance or global command>
    if [[ $COMP_CWORD -eq 1 ]]; then
        _pihx_reply "$_PIHX_GLOBAL_COMMANDS $(_pihx_instances)" "$cur"
        return 0
    fi
    # Global commands take nothing to complete.
    [[ " $_PIHX_GLOBAL_COMMANDS " == *" $name "* ]] && return 0

    # pihx <instance> <command or service>
    if [[ $COMP_CWORD -eq 2 ]]; then
        local commands=$_PIHX_INSTANCE_COMMANDS
        [[ $cmd == openmrs-docker ]] && commands="$commands $_PIHX_OPENMRS_DOCKER_COMMANDS"
        _pihx_reply "$commands $(_pihx_instance_services "$name")" "$cur"
        return 0
    fi

    # An option's value, written `--from dir` or `--from=dir` (bash splits the latter at the =, so
    # the word before the value is "=").
    local option=$prev
    [[ $prev == = ]] && option=${COMP_WORDS[COMP_CWORD-2]}
    case $command:$option in
        initialize:--from | archive:--to)
            _pihx_reply_dirs "$cur"
            return 0
            ;;
        create:--services)
            # A comma-separated list: completes the last name, keeping what's before it.
            local before='' svc available=''
            [[ $cur == *,* ]] && before=${cur%,*},
            for svc in $(_pihx_tools_services "$_PIHX_COMPLETION_TOOLS"); do
                [[ ,$before == *",$svc,"* ]] || available="$available $before$svc"
            done
            _pihx_reply "$available" "$cur"
            _pihx_nospace
            return 0
            ;;
        *:--from-image | *:--output)
            # An image, or a file to write: nothing to offer.
            return 0
            ;;
    esac
    [[ $prev == = ]] && return 0

    local options='' first=false
    [[ $COMP_CWORD -eq 3 ]] && first=true
    case $command in
        add-service)
            if $first; then
                local have available='' svc
                have=" $(_pihx_instance_services "$name" | tr '\n' ' ') "
                for svc in $(_pihx_tools_services "$home/$name/tools"); do
                    [[ $have == *" $svc "* ]] || available="$available $svc"
                done
                _pihx_reply "$available" "$cur"
            fi
            return 0
            ;;
        logs | remove-service)
            $first && _pihx_reply "$(_pihx_instance_services "$name")" "$cur"
            return 0
            ;;
        compose)
            $first && _pihx_reply "$_PIHX_COMPOSE_SUBCOMMANDS" "$cur"
            return 0
            ;;
        use-tools)
            $first && _pihx_reply_dirs "$cur"
            return 0
            ;;
        create) options="--services=" ;;
        config) options="--show-secrets" ;;
        initialize) options="--from --from-image --pull" ;;
        archive) options="--to=" ;;
        run-service) $first && options="--pull" ;;
        summary) options="--output= --include-distribution-artifacts" ;;
        start | update) [[ $cmd == openmrs-docker ]] && options="--build --dev" ;;
        *)
            # pihx <instance> <service> <command>
            if $first && [[ -d $home/$name/tools/services/$command ]]; then
                _pihx_reply "$(_pihx_service_commands "$name" "$command")" "$cur"
            fi
            return 0
            ;;
    esac
    if [[ -n $options ]]; then
        _pihx_reply "$options" "$cur"
        [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == *= ]] && _pihx_nospace
    fi
    return 0
}

complete -F _pihx_complete pihx openmrs-docker
