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
