#!/bin/bash
# Runtime selection and the runtime-neutral contract (Branch 11 / Phase 1-2,
# qnap-dxe-plan.md DQ2). Every dx_runtime_<op> function below dispatches on
# DX_RUNTIME (resolved by bin/lib/dx-config.sh's registry, default `apple`)
# to the matching adapter: bin/lib/dx-runtime-apple.sh for `apple`,
# bin/lib/dx-runtime-docker.sh for `docker-ssh`. No entrypoint, and no name
# in bin/lib/dx-container.sh's wrapper layer, needs to change when a new
# adapter operation lands -- only this file's own two-branch body per
# operation, and the adapter file that implements the new branch.
#
# `dx_runtime_dispatch_ok` rejects anything other than apple/docker-ssh.
# bin/lib/dx-config.sh's own registry validation already refuses an invalid
# DX_RUNTIME during dx_init_config with its own message, before any
# dx_runtime_* function would normally be reached; this dispatch-level guard
# is defence in depth for a caller that invokes one of these functions
# without having gone through config resolution first (for example a test
# that sets DX_RUNTIME directly).
#
# Safe to source: defines functions only, no I/O or command dispatch at
# import time.

DX_RUNTIME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dx-runtime-apple.sh
source "$DX_RUNTIME_LIB_DIR/dx-runtime-apple.sh"
# shellcheck source=dx-runtime-docker.sh
source "$DX_RUNTIME_LIB_DIR/dx-runtime-docker.sh"

dx_runtime_dispatch_ok() {
    case "${DX_RUNTIME:-apple}" in
        apple) return 0 ;;
        docker-ssh) return 0 ;;
        *) echo "Error: unknown DX_RUNTIME '${DX_RUNTIME:-}'." >&2; return 1 ;;
    esac
}

# Every operation below is a plain function call with no intermediate
# subshell or pipe of its own (an `if`/`case` branch, unlike a pipeline,
# does not fork one), so stdin and exit status pass through unchanged from
# caller to adapter to the real `container`/`ssh ... docker` invocation --
# this is proven directly (piped, file-redirected, and argv-verbatim) in
# tests/test_sourceable_coverage.sh for both adapters.
dx_runtime_dispatch() {
    local op="$1"
    shift
    dx_runtime_dispatch_ok || return 1
    if [ "${DX_RUNTIME:-apple}" = docker-ssh ]; then
        "dx_runtime_docker_$op" "$@"
    else
        "dx_runtime_apple_$op" "$@"
    fi
}

# Preflight / host identity.
dx_runtime_available() { dx_runtime_dispatch available "$@"; }
dx_runtime_system_running() { dx_runtime_dispatch system_running "$@"; }
dx_runtime_system_start() { dx_runtime_dispatch system_start "$@"; }
dx_runtime_host_identity() { dx_runtime_dispatch host_identity "$@"; }

# Image: exists, build, list, delete.
dx_runtime_image_exists() { dx_runtime_dispatch image_exists "$@"; }
dx_runtime_image_list() { dx_runtime_dispatch image_list "$@"; }
dx_runtime_image_build() { dx_runtime_dispatch image_build "$@"; }
dx_runtime_image_delete() { dx_runtime_dispatch image_delete "$@"; }

# Volume: exists, create, delete.
dx_runtime_volume_exists() { dx_runtime_dispatch volume_exists "$@"; }
dx_runtime_volume_create() { dx_runtime_dispatch volume_create "$@"; }
dx_runtime_volume_delete() { dx_runtime_dispatch volume_delete "$@"; }

# Container: exists, running, list, create, start, stop, kill, delete.
dx_runtime_container_exists() { dx_runtime_dispatch container_exists "$@"; }
dx_runtime_container_running() { dx_runtime_dispatch container_running "$@"; }
dx_runtime_container_list() { dx_runtime_dispatch container_list "$@"; }
dx_runtime_container_create() { dx_runtime_dispatch container_create "$@"; }
dx_runtime_container_start() { dx_runtime_dispatch container_start "$@"; }
dx_runtime_container_stop() { dx_runtime_dispatch container_stop "$@"; }
dx_runtime_container_kill() { dx_runtime_dispatch container_kill "$@"; }
dx_runtime_container_delete() { dx_runtime_dispatch container_delete "$@"; }

# Ephemeral run (no persistent container) -- see dx-runtime-apple.sh's own
# comment on dx_runtime_apple_run_ephemeral for why this is in the contract
# even though qnap-dxe-plan.md DQ2 does not name it explicitly.
dx_runtime_run_ephemeral() { dx_runtime_dispatch run_ephemeral "$@"; }

# Exec with optional stdin, user, TTY, and captured output; logs and export
# streaming. dx_runtime_dispatch is itself a plain function call with no
# pipe/subshell, and its own body is a bare `if`/`case`, so stdin and exit
# status still pass through to the adapter exactly as the caller attached
# them -- piped, redirected from a file, or a TTY -- unchanged even under
# `set -o pipefail` (see tests/test_sourceable_coverage.sh's dedicated
# proof, which predates and still covers this dispatch shape).
dx_runtime_exec() { dx_runtime_dispatch exec "$@"; }
dx_runtime_logs() { dx_runtime_dispatch logs "$@"; }
dx_runtime_export() { dx_runtime_dispatch export "$@"; }

# Runtime capability queries (qnap-dxe-plan.md DQ2/DQ8): direct named-volume
# mounts, bind mounts, restart policy, host filesystem reclamation. See each
# adapter file's own comment for what its answers mean and why.
dx_runtime_capability() { dx_runtime_dispatch capability "$@"; }
