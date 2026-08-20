#!/bin/bash
# Apple Container adapter. No preflight is performed while this file is sourced.

dx_require_container_cli() {
    command -v container >/dev/null 2>&1 && return 0
    cat >&2 <<'EOF'
Error: Apple 'container' command not found on this host.

The DX Experience requires Apple's container runtime for macOS.
Install it from: https://github.com/apple/container/releases
EOF
    return 1
}

container_system_is_running() { container system status >/dev/null 2>&1; }
container_system_ensure_started() {
    if ! container_system_is_running; then echo "Apple container system is not running; starting it..."; container system start; fi
}

dx_container_list_names() {
    local include_all="$1" output
    if [ "$include_all" = true ]; then
        output="$(container list -a --quiet 2>/dev/null)" && { printf '%s\n' "$output"; return; }
        container list -a | awk 'NR > 1 {print $1}'
    else
        output="$(container list --quiet 2>/dev/null)" && { printf '%s\n' "$output"; return; }
        container list | awk 'NR > 1 {print $1}'
    fi
}

container_exists() { dx_container_list_names true | grep -F -x -q -- "$1"; }
container_is_running() { dx_container_list_names false | grep -F -x -q -- "$1"; }
container_image_exists() {
    local wanted="$1" output
    output="$(container image list --quiet 2>/dev/null)" && {
        printf '%s\n' "$output" | awk -v wanted="$wanted" '$0 == wanted || $0 == wanted ":latest" { found=1 } END { exit !found }'
        return
    }
    container image list | awk -v wanted="$wanted" 'NR > 1 && ($1 == wanted || $1 ":" $2 == wanted) { found=1 } END { exit !found }'
}
container_ensure_volume() { container volume inspect "$1" >/dev/null 2>&1 || container volume create "$1"; }

container_wait_stopped() {
    local name="$1" timeout="$2" elapsed=0
    while container_is_running "$name"; do
        [ "$elapsed" -lt "$timeout" ] || return 1
        echo "Waiting for container $name to stop..."
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

# Parse an exact --uuid argument/value pair from ps output.
container_runtime_pids() {
    ps -axo pid=,command= | awk -v wanted="$1" '/container-runtime-linux/ { for (i = 2; i <= NF; i++) if ($i == "--uuid" && (i + 1) <= NF && $(i + 1) == wanted) { print $1; break } }'
}

container_runtime_identity_matches() {
    local name="$1" pid="$2" start="$3" found
    found="$(container_runtime_pids "$name" | awk -v pid="$pid" '$1 == pid {print; exit}')"
    [ -n "$found" ] && dx_process_identity_matches "$pid" "$start"
}

container_kill_runtime_process() {
    local name="$1" records="" pid start elapsed
    for pid in $(container_runtime_pids "$name"); do
        start="$(dx_process_start_identity "$pid" || true)"
        [ -n "$start" ] && records="${records}${pid}|${start}
"
    done
    [ -n "$records" ] || { echo "No host runtime process found for container $name." >&2; return 1; }
    while IFS='|' read -r pid start; do
        [ -n "$pid" ] || continue
        if container_runtime_identity_matches "$name" "$pid" "$start"; then
            echo "Terminating host runtime process for container $name: $pid" >&2
            kill "$pid" 2>/dev/null || true
        fi
    done <<EOF
$records
EOF
    elapsed=0
    while [ "$elapsed" -lt "$DX_STOP_WAIT_TIMEOUT" ]; do
        [ -z "$(container_runtime_pids "$name")" ] && return 0
        sleep 1; elapsed=$((elapsed + 1))
    done
    while IFS='|' read -r pid start; do
        [ -n "$pid" ] || continue
        if container_runtime_identity_matches "$name" "$pid" "$start"; then
            echo "Runtime process for $name ignored TERM; sending KILL: $pid" >&2
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done <<EOF
$records
EOF
    elapsed=0
    while [ "$elapsed" -lt "$DX_STOP_WAIT_TIMEOUT" ]; do
        [ -z "$(container_runtime_pids "$name")" ] && return 0
        sleep 1; elapsed=$((elapsed + 1))
    done
    echo "Host runtime process for $name is still present." >&2
    return 1
}

container_stop_bounded() {
    local name="$1"
    if ! container_exists "$name"; then echo "Container $name does not exist. Nothing to stop."; return 0; fi
    if ! container_is_running "$name"; then echo "Container $name is already stopped."; return 0; fi
    echo "Stopping DX container: $name..."
    run_with_timeout "$DX_STOP_COMMAND_TIMEOUT" container stop --time "$DX_STOP_GRACE_SECONDS" "$name" || echo "Graceful stop command did not complete cleanly for $name." >&2
    container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT" && return 0
    echo "Container $name did not stop; sending container kill..." >&2
    run_with_timeout "$DX_STOP_COMMAND_TIMEOUT" container kill "$name" || true
    container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT" && return 0
    echo "Container $name is still running after container kill; terminating runtime process..." >&2
    container_kill_runtime_process "$name" || true
    container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT" && return 0
    echo "Container $name is still running after runtime-process fallback." >&2
    return 1
}

# The bootstrap generation the running guest is actually executing, read from
# the launcher's execution lease.
#
# Leases are named "<generation>.<pid>". PID 1 is the launcher: it is the
# container entrypoint and execs that generation's bootstrap.sh, so its lease
# alone names the code that is running. Other PIDs' leases are from earlier
# boots on this volume and must never be mistaken for it. Takes the lease
# listing as data (generation ids are restricted to [A-Za-z0-9_.-], so word
# splitting is safe) and returns non-zero when no launcher lease is present,
# which is the normal state of a guest that has never been synced.
dx_bootstrap_lease_generation() {
    local lease
    for lease in $1; do
        case "$lease" in
            *.1) printf '%s\n' "${lease%.1}"; return 0 ;;
        esac
    done
    return 1
}

# A deterministic digest of the bootstrap payload, used to decide whether a sync
# has anything to publish.
#
# Generation ids are minted from the clock ("<date>-<pid>"), so every sync used
# to produce a new id and repoint `current` even when the payload was byte for
# byte identical. dx-start-container syncs *after* starting the container, so
# the guest was then permanently "running an older generation" than the one just
# published, and the drift warning fired on every start -- which meant it could
# not distinguish a real unsynced change from the sync that had just run.
#
# Hashes the per-file digest listing, which carries both path and content, so a
# rename counts as a change. Modes deliberately do not: the guest re-derives
# them by name when it publishes, so a mode difference is not a content
# difference. Files only -- the payload has no symlinks and no meaningful empty
# directories.
#
# The tool pick is duplicated across the two branches rather than factored into
# a helper because `find -exec` needs a real command, not a shell function, and
# a shell loop feeding a pipeline is not reliably instrumentable by the coverage
# gate. `-exec ... +` also runs nothing on an empty tree, where `xargs` would
# hang waiting on stdin.
dx_bootstrap_content_digest() {
    local source="$1" digest
    [ -d "$source" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(cd "$source" && find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum)" || return 1
    else
        digest="$(cd "$source" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)" || return 1
    fi
    digest="${digest%% *}"
    case "$digest" in ''|*[!0-9a-f]*) return 1 ;; esac
    printf '%s\n' "$digest"
}

# Announce that the guest is running an older generation than the published
# one. dx-start-container has to start the container before it can sync -- the
# payload crosses `container exec`, which needs a running container -- and the
# guest's launcher proceeds as soon as a `current` pointer exists, so a start
# following a bootstrap edit boots the previous generation. This does not fix
# that (see dx-start-plan.md); it makes the condition visible at the moment it
# happens instead of leaving it to be rediscovered as "my fix did nothing".
# Silent unless both generations are known and differ: an unsynced guest has no
# lease, and an unchanged tree republishes the same id.
dx_bootstrap_report_drift() {
    local running="$1" published="$2" name="$3"
    [ -n "$running" ] && [ -n "$published" ] && [ "$running" != "$published" ] || return 0
    echo "Warning: $name is running bootstrap generation $running, but $published is now published." >&2
    echo "The guest boots whichever generation was current when it started, so a bootstrap change needs one more start to take effect." >&2
    echo "Run dx-start-container again to pick it up." >&2
    return 0
}
dx_nix_volume_claim_dir() { printf '%s/.dx-cache/nix-volume-claims\n' "${HOME:?}"; }

dx_nix_volume_claim_name_valid() {
    case "$1" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
}

dx_nix_volume_claim_read() {
    local claim="$1" record container_name pid start extra
    record="$(cat "$claim" 2>/dev/null)" || return 1
    case "$record" in *$'\n'*) return 1 ;; esac
    IFS="$(printf '\t')" read -r container_name pid start extra <<EOF
$record
EOF
    dx_nix_volume_claim_name_valid "$container_name" \
        && case "$pid" in *[!0-9]*|'') return 1 ;; esac \
        && [ -n "$start" ] && [ -z "$extra" ] || return 1
    printf '%s\t%s\t%s\n' "$container_name" "$pid" "$start"
}

dx_nix_volume_claim_acquire() {
    local volume="$1" container_name="$2" directory claim lock temporary record claim_container claim_pid claim_start
    dx_nix_volume_claim_name_valid "$volume" && dx_nix_volume_claim_name_valid "$container_name" || {
        echo "Error: refusing unsafe Nix-volume claim name." >&2
        return 1
    }
    directory="$(dx_nix_volume_claim_dir)"
    mkdir -p "$directory" || return 1
    [ ! -L "$directory" ] && [ -d "$directory" ] || { echo "Error: refusing unsafe Nix-volume claim directory $directory." >&2; return 1; }
    chmod 0700 "$directory"
    claim="$directory/$volume"; lock="$directory/.${volume}.lock"
    dx_lock_acquire "$lock" "${DX_TUNNEL_LOCK_TIMEOUT:-5}" || return 1
    [ ! -L "$claim" ] && { [ ! -e "$claim" ] || [ -f "$claim" ]; } || { echo "Error: refusing unsafe Nix-volume claim path $claim." >&2; dx_lock_release "$lock" || true; return 1; }
    if [ -e "$claim" ]; then
        if ! record="$(dx_nix_volume_claim_read "$claim")"; then
            echo "Error: refusing malformed Nix-volume claim $claim." >&2
            dx_lock_release "$lock" || true
            return 1
        fi
        IFS="$(printf '\t')" read -r claim_container claim_pid claim_start <<EOF
$record
EOF
        if container_exists "$claim_container"; then
            if [ "$claim_container" = "$container_name" ]; then
                dx_lock_release "$lock"
                return 0
            fi
            echo "Error: Nix volume $volume is already claimed by container $claim_container; destroy it or choose a distinct DX_NIX_VOLUME." >&2
            dx_lock_release "$lock" || true
            return 1
        fi
        if dx_process_identity_matches "$claim_pid" "$claim_start"; then
            echo "Error: Nix volume $volume is reserved while container $claim_container is being created." >&2
            dx_lock_release "$lock" || true
            return 1
        fi
    fi
    temporary="$(mktemp "$directory/.${volume}.claim.XXXXXX")" || { dx_lock_release "$lock" || true; return 1; }
    printf '%s\t%s\t%s\n' "$container_name" "$$" "$DXE_SELF_PROCESS_IDENTITY" > "$temporary" \
        && mv -f "$temporary" "$claim" || { rm -f "$temporary"; dx_lock_release "$lock" || true; return 1; }
    dx_lock_release "$lock"
}

dx_nix_volume_claim_release() {
    local volume="$1" container_name="$2" directory claim lock record claim_container claim_pid claim_start
    dx_nix_volume_claim_name_valid "$volume" && dx_nix_volume_claim_name_valid "$container_name" || return 1
    directory="$(dx_nix_volume_claim_dir)"; claim="$directory/$volume"; lock="$directory/.${volume}.lock"
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 0
    dx_lock_acquire "$lock" "${DX_TUNNEL_LOCK_TIMEOUT:-5}" || return 1
    [ ! -L "$claim" ] && { [ ! -e "$claim" ] || [ -f "$claim" ]; } || { dx_lock_release "$lock" || true; return 1; }
    if [ -e "$claim" ]; then
        record="$(dx_nix_volume_claim_read "$claim")" || { dx_lock_release "$lock" || true; return 1; }
        IFS="$(printf '\t')" read -r claim_container claim_pid claim_start <<EOF
$record
EOF
        [ "$claim_container" != "$container_name" ] || rm -f "$claim"
    fi
    dx_lock_release "$lock"
}
