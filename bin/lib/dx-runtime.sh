#!/bin/bash
# Runtime selection and the runtime-neutral contract (Branch 11 / Phase 1,
# qnap-dxe-plan.md DQ2). Every dx_runtime_<op> function below dispatches on
# DX_RUNTIME (resolved by bin/lib/dx-config.sh's registry, default `apple`)
# to the matching adapter. Phase 1 ships only the Apple adapter
# (bin/lib/dx-runtime-apple.sh); a Docker adapter is Phase 2's job, added
# alongside a second branch in each function below -- no entrypoint changes
# again when that lands.
#
# `dx_runtime_dispatch_ok` rejects DX_RUNTIME=docker with a clear message.
# bin/lib/dx-config.sh's own registry validation already refuses that value
# during dx_init_config with the same message, before any dx_runtime_*
# function would normally be reached; this dispatch-level guard is defence
# in depth for a caller that invokes one of these functions without having
# gone through config resolution first (for example a test that sets
# DX_RUNTIME directly).
#
# Safe to source: defines functions only, no I/O or command dispatch at
# import time.

DX_RUNTIME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dx-runtime-apple.sh
source "$DX_RUNTIME_LIB_DIR/dx-runtime-apple.sh"

dx_runtime_dispatch_ok() {
    case "${DX_RUNTIME:-apple}" in
        apple) return 0 ;;
        docker) echo "Error: DX_RUNTIME=docker is not implemented until Phase 2." >&2; return 1 ;;
        *) echo "Error: unknown DX_RUNTIME '${DX_RUNTIME:-}'." >&2; return 1 ;;
    esac
}

# Preflight / host identity.
dx_runtime_available() { dx_runtime_dispatch_ok && dx_runtime_apple_available; }
dx_runtime_system_running() { dx_runtime_dispatch_ok && dx_runtime_apple_system_running; }
dx_runtime_system_start() { dx_runtime_dispatch_ok && dx_runtime_apple_system_start; }
dx_runtime_host_identity() { dx_runtime_dispatch_ok && dx_runtime_apple_host_identity "$@"; }

# Image: exists, build, list, delete.
dx_runtime_image_exists() { dx_runtime_dispatch_ok && dx_runtime_apple_image_exists "$@"; }
dx_runtime_image_list() { dx_runtime_dispatch_ok && dx_runtime_apple_image_list "$@"; }
dx_runtime_image_build() { dx_runtime_dispatch_ok && dx_runtime_apple_image_build "$@"; }
dx_runtime_image_delete() { dx_runtime_dispatch_ok && dx_runtime_apple_image_delete "$@"; }

# Volume: exists, create, delete.
dx_runtime_volume_exists() { dx_runtime_dispatch_ok && dx_runtime_apple_volume_exists "$@"; }
dx_runtime_volume_create() { dx_runtime_dispatch_ok && dx_runtime_apple_volume_create "$@"; }
dx_runtime_volume_delete() { dx_runtime_dispatch_ok && dx_runtime_apple_volume_delete "$@"; }

# Container: exists, running, list, create, start, stop, kill, delete.
dx_runtime_container_exists() { dx_runtime_dispatch_ok && dx_runtime_apple_container_exists "$@"; }
dx_runtime_container_running() { dx_runtime_dispatch_ok && dx_runtime_apple_container_running "$@"; }
dx_runtime_container_list() { dx_runtime_dispatch_ok && dx_runtime_apple_container_list "$@"; }
dx_runtime_container_create() { dx_runtime_dispatch_ok && dx_runtime_apple_container_create "$@"; }
dx_runtime_container_start() { dx_runtime_dispatch_ok && dx_runtime_apple_container_start "$@"; }
dx_runtime_container_stop() { dx_runtime_dispatch_ok && dx_runtime_apple_container_stop "$@"; }
dx_runtime_container_kill() { dx_runtime_dispatch_ok && dx_runtime_apple_container_kill "$@"; }
dx_runtime_container_delete() { dx_runtime_dispatch_ok && dx_runtime_apple_container_delete "$@"; }

# Ephemeral run (no persistent container) -- see dx-runtime-apple.sh's own
# comment on dx_runtime_apple_run_ephemeral for why this is in the contract
# even though qnap-dxe-plan.md DQ2 does not name it explicitly.
dx_runtime_run_ephemeral() { dx_runtime_dispatch_ok && dx_runtime_apple_run_ephemeral "$@"; }

# Exec with optional stdin, user, TTY, and captured output; logs and export
# streaming. A plain function call with no intermediate subshell or pipe of
# its own, so stdin passes through to the adapter (and from there to the
# real `container exec`) exactly as the caller attached it -- piped,
# redirected from a file, or a TTY -- and the guest command's exit status is
# this function's own return status, unchanged, even under `set -o
# pipefail` (see tests/test_sourceable_coverage.sh's dedicated proof).
dx_runtime_exec() { dx_runtime_dispatch_ok && dx_runtime_apple_exec "$@"; }
dx_runtime_logs() { dx_runtime_dispatch_ok && dx_runtime_apple_logs "$@"; }
dx_runtime_export() { dx_runtime_dispatch_ok && dx_runtime_apple_export "$@"; }

# Runtime capability queries (qnap-dxe-plan.md DQ2/DQ8): direct named-volume
# mounts, bind mounts, restart policy, host filesystem reclamation. No
# entrypoint calls this in Phase 1; see dx-runtime-apple.sh's own comment
# for what each Apple answer means and why.
dx_runtime_capability() { dx_runtime_dispatch_ok && dx_runtime_apple_capability "$@"; }
