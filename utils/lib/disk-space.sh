# Free-space checks for the utils/ scripts and openmrs-docker initialize: estimate what a restore or
# backup will write, and refuse before writing anything if there's clearly not enough room, rather
# than failing part way with half-filled volumes or files. Sourced, not run.
#
# SKIP_DISK_SPACE_CHECK=true skips the check (e.g. when an estimate is known to be too high).
# DISK_SPACE_FREE_KB, for tests only, replaces the measured free space.
#
# Sizes are in KiB. Every size is measured in a container, so it works the same for a named volume
# or a host directory, including files the host user can't read.

# Size of a directory or named volume (absolute host path or volume name), minus any of the given
# subpaths within it.
disk_space_size_of() { # <dir or volume> [subpath to leave out...]
    local src=$1; shift
    docker run --rm -v "$src:/s:ro" alpine:3.21 sh -c '
        total=$(du -sk /s | cut -f1)
        for sub in "$@"; do [ -e "/s/$sub" ] && total=$((total - $(du -sk "/s/$sub" | cut -f1))); done
        echo "$total"' sh "$@"
}

disk_space_file_size() { # <file>
    local bytes
    bytes=$(stat -c %s "$1" 2>/dev/null || stat -f %z "$1")
    echo $(( (bytes + 1023) / 1024 ))
}

# What a gzip file holds, uncompressed. gzip records it modulo 4 GiB, so a reading smaller than the
# file itself is wrong; the compressed size is used then.
disk_space_gzip_size() { # <file.gz>
    local compressed uncompressed
    compressed=$(disk_space_file_size "$1")
    uncompressed=$(gzip -l "$1" | awk 'NR == 2 { print int(($2 + 1023) / 1024) }')
    if [ -n "$uncompressed" ] && [ "$uncompressed" -ge "$compressed" ]; then echo "$uncompressed"; else echo "$compressed"; fi
}

# What a .7z/.zip holds, uncompressed, from its listing (ARCHIVE_PASSWORD, if set, for a protected
# one, whose file list may itself be encrypted).
disk_space_7z_size() { # <archive>
    local dir
    dir=$(cd "$(dirname "$1")" && pwd)
    ARCHIVE_PW="${ARCHIVE_PASSWORD:-}" docker run --rm -e ARCHIVE_PW -e ARCHIVE_SRC="$(basename "$1")" \
        -v "$dir:/archive:ro" partnersinhealth/p7zip \
        sh -c '7z l -slt -p"$ARCHIVE_PW" "/archive/$ARCHIVE_SRC"' \
        | awk -F' = ' '$1 == "Size" { total += $2 } END { print int((total + 1023) / 1024) }'
}

# What an archive (.7z, .zip, .tar.gz, .tgz, .tar) or plain file holds, uncompressed.
disk_space_contents_size() { # <file>
    case "$1" in
        *.7z|*.zip) disk_space_7z_size "$1" ;;
        *.tar.gz|*.tgz|*.gz) disk_space_gzip_size "$1" ;;
        *) disk_space_file_size "$1" ;;
    esac
}

# Free space on the filesystem a path would be written to (its nearest existing ancestor).
disk_space_free_at() { # <path>
    local dir=$1
    until [ -e "$dir" ]; do dir=$(dirname "$dir"); done
    df -Pk "$dir" | awk 'NR == 2 { print $4 }'
}

# Free space where Docker keeps named volumes: an anonymous volume is created on the same
# filesystem (the local driver's directory), and removed with the container.
disk_space_free_on_docker_volumes() {
    docker run --rm -v /v alpine:3.21 df -Pk /v | awk 'NR == 2 { print $4 }'
}

disk_space_human() { # <KiB>
    awk -v k="$1" 'BEGIN {
        if (k >= 1048576) printf "%.1fG", k / 1048576
        else if (k >= 1024) printf "%.1fM", k / 1024
        else printf "%dK", k }'
}

# Refuses (exit 1) unless <free> is at least <needed> plus 10%. <what> and <where> are for messages.
disk_space_require() { # <what> <needed KiB> <free KiB> <where>
    local what=$1 needed=$2 free=${DISK_SPACE_FREE_KB:-$3} where=$4
    case "$needed$free" in
        ''|*[!0-9]*) echo "warning: couldn't estimate the disk space $what needs; not checked." >&2; return 0 ;;
    esac
    if [ "${SKIP_DISK_SPACE_CHECK:-}" = true ]; then
        echo "Disk space: $what needs about $(disk_space_human "$needed"); not checked (SKIP_DISK_SPACE_CHECK=true)." >&2
        return 0
    fi
    if [ "$free" -lt $((needed + needed / 10)) ]; then
        echo "error: not enough disk space on $where: $what needs about $(disk_space_human "$needed") (plus 10%), and $(disk_space_human "$free") is free. Free up space, or set SKIP_DISK_SPACE_CHECK=true to go ahead anyway." >&2
        exit 1
    fi
    echo "Disk space: $what needs about $(disk_space_human "$needed"); $(disk_space_human "$free") free on $where." >&2
}
