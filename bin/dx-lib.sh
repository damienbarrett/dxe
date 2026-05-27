#!/bin/bash
set -euo pipefail
# dx-lib.sh
# Shared library for DX Experience scripts

# Locate the project root
export DX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DX_PROJECT_ROOT="$(cd "$DX_LIB_DIR/.." && pwd)"

# Load .env file if it exists
if [ -f "$DX_PROJECT_ROOT/.env" ]; then
    # Load .env file safely ignoring comments
    set -a
    source <(grep -v '^#' "$DX_PROJECT_ROOT/.env" | sed -e '/^$/d')
    set +a
fi

# Set defaults for common variables
export DX_CONTAINER_NAME="${DX_CONTAINER_NAME:-dx-host}"
export DX_IMAGE="${DX_IMAGE:-dx-nixos-25.11}"
export DX_SSH_PORT="${DX_SSH_PORT:-2222}"
export DX_SSH_KEY="${DX_SSH_KEY:-$DX_PROJECT_ROOT/dx_key}"
export DX_SSH_KEY_PUB="${DX_SSH_KEY_PUB:-$DX_PROJECT_ROOT/dx_key.pub}"
export DX_SSH_CONNECT_TIMEOUT="${DX_SSH_CONNECT_TIMEOUT:-15}"
export DX_CONTEXT_DIR="${DX_CONTEXT_DIR:-$DX_PROJECT_ROOT/container/aarch64-darwin-apple-container-dx-nixos-25.11}"
export DX_BOOTSTRAP_SOURCE="${DX_BOOTSTRAP_SOURCE:-$DX_CONTEXT_DIR}"
export DX_BOOTSTRAP_VOLUME="${DX_BOOTSTRAP_VOLUME:-dx-bootstrap}"
export DX_BOOTSTRAP_PATH="${DX_BOOTSTRAP_PATH:-/guest-bootstrap}"
export DX_BOOTSTRAP_WAIT_TIMEOUT="${DX_BOOTSTRAP_WAIT_TIMEOUT:-30}"
export DX_NIX_VOLUME="${DX_NIX_VOLUME:-dx-nix}"
export DX_NIX_DISK="${DX_NIX_DISK:-$HOME/.dx-cache/nix-store.img}"
export DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-20G}"
export DX_WORKSPACE_VOLUME="${DX_WORKSPACE_VOLUME:-dx-workspace}"
export DX_WORKSPACE_PATH="${DX_WORKSPACE_PATH:-/workspace}"
export DX_STOP_GRACE_SECONDS="${DX_STOP_GRACE_SECONDS:-5}"
export DX_STOP_COMMAND_TIMEOUT="${DX_STOP_COMMAND_TIMEOUT:-15}"
export DX_STOP_WAIT_TIMEOUT="${DX_STOP_WAIT_TIMEOUT:-5}"
export DX_DELETE_COMMAND_TIMEOUT="${DX_DELETE_COMMAND_TIMEOUT:-15}"

# Check for Apple Container installation
if ! command -v container &> /dev/null; then
    cat >&2 <<'EOF'
Error: Apple 'container' command not found on this host.

The DX Experience requires Apple's container runtime for macOS.

Install it from:
  https://github.com/apple/container/releases

After installing, re-run this command.
EOF
    exit 1
fi

# Helper: is the Apple container system (apiserver / launchd services) running?
container_system_is_running() {
    container system status >/dev/null 2>&1
}

# Helper: ensure the Apple container system is running, starting it if needed.
container_system_ensure_started() {
    if container_system_is_running; then
        return 0
    fi
    echo "Apple container system is not running; starting it..."
    container system start
}

# Helper function to check if a container exists (exact match)
container_exists() {
    local name="$1"
    # use -a to include stopped containers, awk to match the exact name
    container list -a | awk '{print $1}' | grep -x -q "$name"
}

# Helper function to check if a container is running (exact match)
container_is_running() {
    local name="$1"
    # Check if container is in the list of running containers
    container list | awk '{print $1}' | grep -x -q "$name"
}

# Helper function to check if a container image exists (exact match)
container_image_exists() {
    local name="$1"
    container image list | awk '{print $1}' | grep -x -q "$name"
}

# Idempotently create a named volume.
container_ensure_volume() {
    local name="$1"
    if container volume inspect "$name" >/dev/null 2>&1; then
        return 0
    fi
    container volume create "$name"
}

run_with_timeout() {
    local timeout="$1"
    shift

    "$@" &
    local pid=$!
    local timeout_marker="${TMPDIR:-/tmp}/dx-timeout.$$.$pid"
    rm -f "$timeout_marker"

    (
        sleep "$timeout"
        if kill -0 "$pid" 2>/dev/null; then
            echo "Command timed out after ${timeout}s: $*" >&2
            : > "$timeout_marker"
            kill "$pid" 2>/dev/null || true
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!

    local status=0
    if wait "$pid" 2>/dev/null; then
        status=0
    else
        status=$?
    fi

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ -f "$timeout_marker" ]; then
        rm -f "$timeout_marker"
        return 124
    fi

    rm -f "$timeout_marker"
    return "$status"
}

container_wait_stopped() {
    local name="$1"
    local timeout="$2"
    local elapsed=0

    while container_is_running "$name"; do
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
        echo "Waiting for container $name to stop..."
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

container_runtime_pids() {
    local name="$1"
    # Apple Container 0.12.0 starts runtime processes like:
    # container-runtime-linux start --root .../containers/dx-host --uuid dx-host
    ps -axo pid=,command= | awk -v name="$name" '
        $0 ~ /container-runtime-linux/ && index($0, "--uuid " name) { print $1 }
    '
}

container_kill_runtime_process() {
    local name="$1"
    local pids
    pids="$(container_runtime_pids "$name")"

    if [ -z "$pids" ]; then
        echo "No host runtime process found for container $name." >&2
        echo "  (searched: ps -axo pid=,command= for container-runtime-linux with --uuid $name)" >&2
        return 1
    fi

    echo "Terminating host runtime process for container $name: $pids" >&2
    kill $pids 2>/dev/null || true

    local elapsed=0
    while [ "$elapsed" -lt "$DX_STOP_WAIT_TIMEOUT" ]; do
        if [ -z "$(container_runtime_pids "$name")" ]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    pids="$(container_runtime_pids "$name")"
    if [ -n "$pids" ]; then
        echo "Runtime process for $name ignored TERM; sending KILL: $pids" >&2
        kill -KILL $pids 2>/dev/null || true
    fi

    elapsed=0
    while [ "$elapsed" -lt "$DX_STOP_WAIT_TIMEOUT" ]; do
        if [ -z "$(container_runtime_pids "$name")" ]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "Host runtime process for $name is still present." >&2
    return 1
}

container_stop_bounded() {
    local name="$1"

    if ! container_exists "$name"; then
        echo "Container $name does not exist. Nothing to stop."
        return 0
    fi

    if ! container_is_running "$name"; then
        echo "Container $name is already stopped."
        return 0
    fi

    echo "Stopping DX container: $name..."
    if ! run_with_timeout "$DX_STOP_COMMAND_TIMEOUT" container stop --time "$DX_STOP_GRACE_SECONDS" "$name"; then
        echo "Graceful stop command did not complete cleanly for $name." >&2
    fi

    if container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT"; then
        return 0
    fi

    echo "Container $name did not stop; sending container kill..." >&2
    run_with_timeout "$DX_STOP_COMMAND_TIMEOUT" container kill "$name" || true

    if container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT"; then
        return 0
    fi

    echo "Container $name is still running after container kill; terminating runtime process..." >&2
    container_kill_runtime_process "$name" || true

    if container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT"; then
        return 0
    fi

    echo "Container $name is still running after runtime-process fallback." >&2
    return 1
}

dx_bootstrap_launch_command() {
    printf '%s\n' "set -eu; mkdir -p \"$DX_WORKSPACE_PATH\" \"$DX_BOOTSTRAP_PATH\"; rm -f \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-ready\"; touch \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-waiting\"; echo 'Waiting for bootstrap payload in $DX_BOOTSTRAP_PATH...'; while [ ! -f \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-ready\" ]; do sleep 1; done; rm -f \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-waiting\"; exec \"$DX_BOOTSTRAP_PATH/bootstrap.sh\" serve"
}

dx_get_host_timezone() {
    readlink /etc/localtime | sed 's#^.*/zoneinfo/##'
}
