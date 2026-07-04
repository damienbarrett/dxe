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

# Fail fast on retired persistence variables before defaults are assigned.
if [ -n "${DX_WORKSPACE_VOLUME:-}" ] || [ -n "${DX_WORKSPACE_PATH:-}" ]; then
    echo "Error: workspace persistence variables were renamed." >&2
    echo "Use DX_PERSIST_VOLUME for the persistent volume and remove DX_WORKSPACE_PATH; /persist is fixed." >&2
    exit 1
fi

# Set defaults for common variables
export DX_CONTAINER_NAME="${DX_CONTAINER_NAME:-dx-host}"
export DX_IMAGE="${DX_IMAGE:-dx-nixos-26.05}"
export DX_SSH_PORT="${DX_SSH_PORT:-2222}"
export DX_SSH_KEY="${DX_SSH_KEY:-$DX_PROJECT_ROOT/dx_key}"
export DX_SSH_KEY_PUB="${DX_SSH_KEY_PUB:-$DX_PROJECT_ROOT/dx_key.pub}"
export DX_SSH_CONNECT_TIMEOUT="${DX_SSH_CONNECT_TIMEOUT:-15}"
export DX_CONTEXT_DIR="${DX_CONTEXT_DIR:-$DX_PROJECT_ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05}"
export DX_BOOTSTRAP_SOURCE="${DX_BOOTSTRAP_SOURCE:-$DX_CONTEXT_DIR}"
export DX_BOOTSTRAP_VOLUME="${DX_BOOTSTRAP_VOLUME:-dx-bootstrap}"
export DX_BOOTSTRAP_PATH="${DX_BOOTSTRAP_PATH:-/guest-bootstrap}"
export DX_BOOTSTRAP_WAIT_TIMEOUT="${DX_BOOTSTRAP_WAIT_TIMEOUT:-30}"
export DX_GUEST_ACTIVATION_TIMEOUT="${DX_GUEST_ACTIVATION_TIMEOUT:-1800}"
export DX_GUEST_ACTIVATION_ATTEMPTS="${DX_GUEST_ACTIVATION_ATTEMPTS:-2}"
export DX_GUEST_ACTIVATION_RETRY_DELAY="${DX_GUEST_ACTIVATION_RETRY_DELAY:-5}"
export DX_NIX_VOLUME="${DX_NIX_VOLUME:-dx-nix}"
export DX_NIX_MOUNT="${DX_NIX_MOUNT:-/nix}"
export DX_NIX_DISK="${DX_NIX_DISK:-$HOME/.dx-cache/nix-store.img}"
export DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-20G}"
export DX_PERSIST_VOLUME="${DX_PERSIST_VOLUME:-dx-persist}"
export DX_GIT_MOUNT_SOURCE="${DX_GIT_MOUNT_SOURCE:-}"
export DX_GIT_MOUNT_TARGET="${DX_GIT_MOUNT_TARGET:-/workspace}"
export DX_GUEST_WORKDIR="${DX_GUEST_WORKDIR:-}"
export DX_CONTAINER_MEMORY="${DX_CONTAINER_MEMORY:-12G}"
export DX_CONTAINER_CPUS="${DX_CONTAINER_CPUS:-4}"
export DX_CONTAINER_VOLUME_DIR="${DX_CONTAINER_VOLUME_DIR:-$HOME/Library/Application Support/com.apple.container/volumes}"
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

dx_require_non_reserved_container_name() {
    local name="$1"
    if [ "$name" = "dx-host" ]; then
        echo "Error: dx-host is reserved for the default durable guest." >&2
        return 1
    fi
}

# Reject container names before they are ever used to build a path (e.g. a
# mount identity marker file). No slashes, no leading '-' or '.', no empty
# string.
dx_require_container_safe_name() {
    local name="$1"
    if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        echo "Error: --container name '$name' is not valid." >&2
        echo "Names must match ^[A-Za-z0-9][A-Za-z0-9_.-]*\$ (no '/', no leading '-' or '.', not empty)." >&2
        return 1
    fi
}

dx_slugify() {
    local value="$1"
    local fallback="${2:-item}"
    local max_len="${3:-32}"
    local slug

    slug="$(printf '%s' "$value" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
    if [ -z "$slug" ]; then
        slug="$fallback"
    fi
    printf '%s' "${slug:0:$max_len}" | sed -E 's/-+$//'
}

dx_short_hash() {
    local value="$1"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$value" | shasum -a 256 | awk '{print substr($1, 1, 10)}'
    else
        printf '%s' "$value" | sha256sum | awk '{print substr($1, 1, 10)}'
    fi
}

dx_derived_name() {
    local prefix="$1"
    local identity="$2"
    local display="${3:-$identity}"
    local slug hash name

    slug="$(dx_slugify "$(basename "$display")" item 32)"
    hash="$(dx_short_hash "$identity")"
    name="${prefix}${slug}-${hash}"
    dx_require_non_reserved_container_name "$name"
    printf '%s\n' "$name"
}

dx_derived_port() {
    local identity="$1"
    local hash_int

    hash_int="$((0x$(dx_short_hash "$identity" | cut -c1-6)))"
    # Keep derived side-container SSH ports out of dx-host (2222) and dx-test
    # (2299), while staying in the unprivileged range.
    printf '%s\n' "$((2300 + (hash_int % 17000)))"
}

dx_port_in_use() {
    local port="$1"
    # A successful loopback connect means something already owns the port.
    # /dev/tcp avoids a dependency on nc/lsof; the fd closes with the subshell.
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

dx_require_positive_integer() {
    local name="$1"
    local value="$2"

    case "$value" in
        ''|*[!0-9]*|0)
            echo "Error: $name must be a positive integer, got '$value'." >&2
            return 1
            ;;
    esac
}

dx_default_ssh_wait_timeout() {
    local bootstrap_grace=1800
    local wait_timeout

    dx_require_positive_integer DX_GUEST_ACTIVATION_TIMEOUT "$DX_GUEST_ACTIVATION_TIMEOUT"
    dx_require_positive_integer DX_GUEST_ACTIVATION_ATTEMPTS "$DX_GUEST_ACTIVATION_ATTEMPTS"
    dx_require_positive_integer DX_GUEST_ACTIVATION_RETRY_DELAY "$DX_GUEST_ACTIVATION_RETRY_DELAY"

    # Each activation attempt can consume its configured timeout plus the
    # 30-second forced-kill grace in bootstrap.sh. Include every retry delay
    # and a bounded allowance for rebuilding the root bootstrap toolchain on a
    # clean image before the persistent Nix store can be mounted.
    wait_timeout=$((DX_GUEST_ACTIVATION_ATTEMPTS * (DX_GUEST_ACTIVATION_TIMEOUT + 30)
        + (DX_GUEST_ACTIVATION_ATTEMPTS - 1) * DX_GUEST_ACTIVATION_RETRY_DELAY
        + bootstrap_grace))
    printf '%s\n' "$wait_timeout"
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
    printf '%s\n' "set -eu; mkdir -p /persist \"$DX_BOOTSTRAP_PATH\"; rm -f \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-ready\"; touch \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-waiting\"; echo 'Waiting for bootstrap payload in $DX_BOOTSTRAP_PATH...'; while [ ! -f \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-ready\" ]; do sleep 1; done; rm -f \"$DX_BOOTSTRAP_PATH/.dx-bootstrap-waiting\"; exec \"$DX_BOOTSTRAP_PATH/bootstrap.sh\" serve"
}

dx_get_host_timezone() {
    local tz=""
    local localtime_target=""

    if [ -L /etc/localtime ]; then
        localtime_target="$(readlink /etc/localtime || true)"
        if [ -n "$localtime_target" ] && printf '%s\n' "$localtime_target" | grep -q '/zoneinfo/'; then
            tz="$(printf '%s\n' "$localtime_target" | sed 's#^.*/zoneinfo/##')"
        fi
    fi

    if [ -z "$tz" ] && [ -f /etc/timezone ]; then
        tz="$(sed -n '1{s/[[:space:]]*$//;p;}' /etc/timezone)"
    fi

    if [ -z "$tz" ] && command -v systemsetup >/dev/null 2>&1; then
        tz="$(systemsetup -gettimezone 2>/dev/null | sed -n 's/^Time Zone: //p' || true)"
    fi

    if [ -z "$tz" ]; then
        echo "Warning: could not detect host timezone; defaulting guest timezone to UTC." >&2
        tz="UTC"
    fi

    printf '%s\n' "$tz"
}
