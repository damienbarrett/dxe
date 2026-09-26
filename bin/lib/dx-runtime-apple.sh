#!/bin/bash
# Apple Container runtime adapter (Branch 11 / Phase 1, qnap-dxe-plan.md DQ2).
#
# Every dx_runtime_apple_<op> function here is the literal Apple `container`
# invocation an entrypoint (or bin/lib/dx-container.sh's own wrapper
# functions) issued directly before this extraction -- commands, flags,
# output shape, and error/timeout handling are unchanged; only the raw call
# site moved. See docs/refactor/runtime-boundary-inventory.md for the
# call-by-call mapping this file implements. bin/lib/dx-runtime.sh is the
# only intended caller (it dispatches on DX_RUNTIME and, for Phase 1, always
# lands here); nothing else should call dx_runtime_apple_* directly except
# bin/lib/dx-container.sh's dx_container_list_names, which keeps its name
# and pre-extraction behavior for tests/test_sourceable_coverage.sh's direct
# callers and has no Docker equivalent to dispatch to.
#
# Safe to source: defines functions only, no command availability exit,
# service start, or I/O at import time.

dx_runtime_apple_available() {
    command -v container >/dev/null 2>&1 && return 0
    cat >&2 <<'EOF'
Error: Apple 'container' command not found on this host.

The DX Experience requires Apple's container runtime for macOS.
Install it from: https://github.com/apple/container/releases
EOF
    return 1
}

dx_runtime_apple_system_running() { container system status >/dev/null 2>&1; }
dx_runtime_apple_system_start() { container system start; }

# `container list [-a] --quiet` is preferred (bare names, no header row); an
# older Apple Container CLI without `--quiet` falls back to the tabular form
# piped through awk to drop the header and take the first column. Both
# branches are exercised at the function level in
# tests/test_sourceable_coverage.sh.
dx_runtime_apple_container_list_names() {
    local include_all="$1" output
    if [ "$include_all" = true ]; then
        output="$(container list -a --quiet 2>/dev/null)" && { printf '%s\n' "$output"; return; }
        container list -a | awk 'NR > 1 {print $1}'
    else
        output="$(container list --quiet 2>/dev/null)" && { printf '%s\n' "$output"; return; }
        container list | awk 'NR > 1 {print $1}'
    fi
}

# No `-q`: see tests/test_helpers.sh's stdin_matches comment for why
# `writer | grep -q` is unsafe under `set -o pipefail` (every caller of these
# two functions). Redirecting to /dev/null instead keeps grep reading to EOF
# so the writer's later `printf` calls never see a closed pipe.
dx_runtime_apple_container_exists() { dx_runtime_apple_container_list_names true | grep -F -x -- "$1" >/dev/null; }
dx_runtime_apple_container_running() { dx_runtime_apple_container_list_names false | grep -F -x -- "$1" >/dev/null; }
dx_runtime_apple_container_list() { container list "$@"; }

dx_runtime_apple_image_exists() {
    local wanted="$1" output
    output="$(container image list --quiet 2>/dev/null)" && {
        printf '%s\n' "$output" | awk -v wanted="$wanted" '$0 == wanted || $0 == wanted ":latest" { found=1 } END { exit !found }'
        return
    }
    container image list | awk -v wanted="$wanted" 'NR > 1 && ($1 == wanted || $1 ":" $2 == wanted) { found=1 } END { exit !found }'
}
dx_runtime_apple_image_list() { container image list "$@"; }
dx_runtime_apple_image_build() { container build "$@"; }
dx_runtime_apple_image_delete() { container image rm "$@"; }

dx_runtime_apple_volume_exists() { container volume inspect "$1" >/dev/null 2>&1; }
dx_runtime_apple_volume_create() { container volume create "$@"; }
dx_runtime_apple_volume_delete() { container volume rm "$@"; }

dx_runtime_apple_container_create() { container create "$@"; }
dx_runtime_apple_container_start() { container start "$@"; }
dx_runtime_apple_container_stop() { container stop "$@"; }
dx_runtime_apple_container_kill() { container kill "$@"; }
dx_runtime_apple_container_delete() { container delete "$@"; }

dx_runtime_apple_exec() { container exec "$@"; }
dx_runtime_apple_logs() { container logs "$@"; }
dx_runtime_apple_export() { container export "$@"; }

# Ephemeral, no-persistent-container run (`container run --rm ...`), used
# today only by bin/dx-migrate-persist to read/copy volume contents without
# a named container. Retries a bounded number of times on Apple Container's
# own runtime-client-attach race for a short-lived container (the exact
# error text below), and nothing else -- moved verbatim from
# dx-migrate-persist's dx_migrate_container_run (this is the operation
# qnap-dxe-plan.md DQ2 does not name explicitly; it is added here because
# an entrypoint uses it today, per the coordinating session's decision
# 2026-09-27: the retry belongs here, not in the caller, because it is
# specifically about the Apple CLI's own race, which any caller of "run"
# would hit). $DX_MIGRATE_RUN_MAX_ATTEMPTS/$DX_MIGRATE_RUN_RETRY_DELAY are
# validated by dx-migrate-persist itself before this is ever called; reading
# them here (rather than passing them as arguments) keeps this function's
# signature identical to a plain `container run` passthrough for every other
# potential caller, while preserving the exact retry behavior in place.
dx_runtime_apple_run_ephemeral() {
    local attempt=1 work_dir rc errtext
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-migrate-run.XXXXXX")" || return 1
    while :; do
        rc=0
        container run "$@" >"$work_dir/out" 2>"$work_dir/err" || rc=$?
        if [ "$rc" -eq 0 ]; then
            cat "$work_dir/out"
            rm -rf "$work_dir"
            return 0
        fi
        errtext="$(cat "$work_dir/err")"
        case "$errtext" in
            *"no runtime client exists: container is stopped"*)
                if [ "$attempt" -ge "${DX_MIGRATE_RUN_MAX_ATTEMPTS:-5}" ]; then
                    echo "Error: container run did not stabilize after ${DX_MIGRATE_RUN_MAX_ATTEMPTS:-5} attempts (Apple Container runtime-client race): $errtext" >&2
                    rm -rf "$work_dir"
                    return "$rc"
                fi
                echo "Warning: container run hit an Apple Container runtime-client race (attempt $attempt/${DX_MIGRATE_RUN_MAX_ATTEMPTS:-5}); retrying..." >&2
                attempt=$((attempt + 1))
                sleep "${DX_MIGRATE_RUN_RETRY_DELAY:-1}"
                ;;
            *)
                printf '%s\n' "$errtext" >&2
                rm -rf "$work_dir"
                return "$rc"
                ;;
        esac
    done
}

# Stable remote-host identity (qnap-dxe-plan.md DQ2's "preflight and stable
# remote-host identity"). Apple Container is always local, so there is no
# remote host to identify; "local" is the fixed answer. No entrypoint reads
# this in Phase 1 (added now, per the coordinating session's decision
# 2026-09-27, so Phase 2's Docker-SSH adapter has a shape to fill in).
dx_runtime_apple_host_identity() { printf '%s\n' local; }

# Runtime capability queries (qnap-dxe-plan.md DQ2/DQ8). No entrypoint reads
# these in Phase 1 either (same reason as host_identity above); Apple's
# answers reflect what bin/dx-create-container, bin/dx-reclaim, and
# bin/dx-nix-disk already do today:
#   direct_named_volume_mounts -- yes: dx-create-container mounts
#     DX_NIX_VOLUME/DX_PERSIST_VOLUME/DX_BOOTSTRAP_VOLUME with `--volume
#     NAME:/path:MODE` directly.
#   bind_mounts -- yes: DX_GIT_MOUNT_SOURCE is a host-directory bind mount,
#     the same `--volume` flag form.
#   restart_policy -- no: dx-create-container passes no restart-policy flag
#     at all today (qnap-dxe-plan.md DQ3's "Apple default: no" is the
#     complete current behavior, not a flag DX_RUNTIME=apple sets).
#   host_filesystem_reclamation -- yes: bin/dx-reclaim's host sparse-image
#     sizing and bin/dx-nix-disk both operate directly on the host
#     filesystem today (outside this contract entirely, per DQ8; this
#     capability answer just records that the capability exists on Apple).
dx_runtime_apple_capability() {
    case "$1" in
        direct_named_volume_mounts|bind_mounts|host_filesystem_reclamation) return 0 ;;
        restart_policy) return 1 ;;
        *) echo "Error: unknown runtime capability '$1'." >&2; return 2 ;;
    esac
}
