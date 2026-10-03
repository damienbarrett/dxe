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

# dx_runtime_guest_ssh_address -- the address the GUEST's own SSH server is
# published on AND reached at (Branch 11 / Phase 5, qnap-dxe-plan.md DQ5;
# docs/refactor/remote-aware-ssh.md section 1). Apple: the fixed loopback
# constant it always used implicitly. Docker-ssh: the NAS's Tailscale IPv4
# address, discovered over the management connection, validated, and cached
# per process -- never the management alias/host identity above, and never
# persisted to any tracked file.
dx_runtime_guest_ssh_address() { dx_runtime_dispatch guest_ssh_address "$@"; }

# Image: exists, build, list, delete, identity.
dx_runtime_image_exists() { dx_runtime_dispatch image_exists "$@"; }
dx_runtime_image_list() { dx_runtime_dispatch image_list "$@"; }
dx_runtime_image_build() { dx_runtime_dispatch image_build "$@"; }
dx_runtime_image_delete() { dx_runtime_dispatch image_delete "$@"; }

# dx_runtime_image_identity <image> -- the runtime's own stable identity for
# an image reference (Branch 11 / Phase 3, docs/refactor/direct-volume-storage.md
# section 5: the host tells the direct-volume guest which image created the
# container, via bin/dx-create-container's DX_IMAGE_IDENTITY env token,
# because the volume's own content cannot independently prove which image
# populated it). Both adapters render "sha256:<hex>"; failure (image
# missing, inspect failed, output unparseable) is a non-zero exit -- callers
# fail closed rather than proceed without an identity.
dx_runtime_image_identity() { dx_runtime_dispatch image_identity "$@"; }

# Volume: exists, create, delete, usage.
dx_runtime_volume_exists() { dx_runtime_dispatch volume_exists "$@"; }
dx_runtime_volume_create() { dx_runtime_dispatch volume_create "$@"; }
dx_runtime_volume_delete() { dx_runtime_dispatch volume_delete "$@"; }

# dx_runtime_volume_owned <name> <verb> -- the ownership check (Astra F3,
# qnap-dxe-plan.md DQ6) bin/lib/dx-container.sh's container_ensure_volume
# runs before ADOPTING an existing volume (never before creating an absent
# one, which needs no ownership proof): DX_RUNTIME=docker-ssh proves it via
# DQ6 labels (bin/lib/dx-runtime-docker-lifecycle.sh's
# dx_runtime_docker_volume_owned); DX_RUNTIME=apple has no per-object
# labels at all (see dx-runtime-apple.sh's own comment on this) and is
# always this one host's own by construction, so its implementation is an
# unconditional success, not a placeholder for a future check.
dx_runtime_volume_owned() { dx_runtime_dispatch volume_owned "$@"; }

# dx_runtime_volume_usage <volume> -- capability-aware size report for
# bin/dx-reclaim (Branch 11 / Phase 3, qnap-dxe-plan.md Phase 3 item 5).
# Apple: today's host sparse-image size (unchanged wording: "missing" for
# an absent image, matching dx-reclaim's pre-existing output exactly).
# Docker: a structured, single-field `docker system df -v` query (never
# table parsing); "unknown" when Docker cannot say (the volume is absent
# from the report, or the query fails).
dx_runtime_volume_usage() { dx_runtime_dispatch volume_usage "$@"; }

# Container: exists, running, list, create, start, stop, kill, delete.
dx_runtime_container_exists() { dx_runtime_dispatch container_exists "$@"; }
dx_runtime_container_running() { dx_runtime_dispatch container_running "$@"; }
# dx_runtime_container_restart_count <name> -- how many times the runtime has
# restarted the container (docker-ssh: its restart policy; Apple: always 0, it
# has no restart policy). bin/dx-wait-ssh uses the rise to spot a crash loop.
dx_runtime_container_restart_count() { dx_runtime_dispatch container_restart_count "$@"; }
dx_runtime_container_list() { dx_runtime_dispatch container_list "$@"; }

# dx_runtime_container_create's parameter vocabulary is deliberately
# runtime-NEUTRAL (qnap-dxe-plan.md DQ2: "runtime-specific CLI syntax ...
# lives only in the adapter"). bin/dx-create-container (its one caller)
# never spells a single Apple or Docker flag name; each adapter's own
# dx_runtime_{apple,docker}_container_create renders its own real create
# argv from this vocabulary, in the order it receives them (this is what
# lets the Apple adapter reproduce today's exact `container create` argv,
# order included -- see tests/test_runtime_boundary_characterisation.sh's
# byte-for-byte proof). Recognized items, each exactly one "--flag value"
# pair (never bundled), passed in the order they should be rendered:
#   --name NAME                required, once
#   --image IMAGE              required, once
#   --volume nix:VOLNAME:MODE               the Nix store volume; no
#                               target -- each adapter decides where to
#                               mount it (Apple stages it for the guest to
#                               reformat; docker-ssh mounts it directly at
#                               /nix per DQ4, never CAP_SYS_ADMIN)
#   --volume persist:VOLNAME:TARGET:MODE    today's target is always the
#                               fixed guest path /persist
#   --volume bootstrap:VOLNAME:TARGET:MODE  target is DX_BOOTSTRAP_PATH
#   --volume git:SRC:TARGET:MODE            optional host bind mount
#   --env KEY=VALUE             repeatable, rendered in the order given
#   --memory MEM
#   --cpus N                   a CPU *count* -- Apple's own -c flag means
#                               this; Docker's own -c means --cpu-shares (a
#                               relative weight, a different unit), so the
#                               Docker adapter renders --cpus, never -c
#   --publish SPEC              HOSTPORT:GUESTPORT, no bind address (Branch
#                               11 / Phase 5, qnap-dxe-plan.md DQ5): each
#                               adapter prepends its own guest SSH address
#                               (dx_runtime_guest_ssh_address) before
#                               rendering its real -p flag -- Apple a fixed
#                               "127.0.0.1:" literal (today's rendered argv
#                               is unaffected byte for byte), docker-ssh the
#                               NAS's discovered Tailscale address, never
#                               the LAN or 0.0.0.0
#   --restart-policy POLICY    DX_CONTAINER_RESTART_POLICY's value; Apple
#                               ignores it completely (it never sets a
#                               restart flag at all, matching
#                               dx_runtime_capability restart_policy=false
#                               for apple); docker-ssh renders --restart
#                               POLICY (Docker accepts "no"/"unless-stopped"
#                               verbatim, no translation needed) plus the
#                               DQ6 labels it computes itself
#   --health-cmd CMD           Branch 11 / Phase 6 (qnap-dxe-plan.md Phase 6
#                               item 4; the one neutral create-time health
#                               flag pre-authorised for this phase), always
#                               passed together with --health-interval and
#                               --health-retries below, never alone. Apple
#                               ignores all three completely (no HEALTHCHECK
#                               concept in `container create`, matching
#                               dx_runtime_capability container_healthcheck
#                               =false for apple); docker-ssh renders
#                               --health-cmd CMD --health-interval DURATION
#                               --health-retries N verbatim (Docker's own
#                               flag names, no translation needed). CMD must
#                               be SSH-independent -- reachable through
#                               `docker exec`/`container exec`'s own plane,
#                               never the guest's network stack -- so a
#                               transient tailnet issue never reports the
#                               guest unhealthy.
#   --health-interval DURATION Docker duration syntax (e.g. "10s"); ignored
#                               by Apple like --health-cmd above.
#   --health-retries N         Consecutive failures before Docker reports
#                               "unhealthy"; ignored by Apple like
#                               --health-cmd above.
#   --entrypoint-cmd CMD
#   --entrypoint-arg ARG        repeatable, rendered in order -- the
#                               trailing "-- ARGS" both CLIs agree is the
#                               entrypoint's own argv, never re-parsed as
#                               create's own options
#
# Splits one "--volume" spec into DXE_VOLSPEC_{ROLE,NAME,TARGET,MODE}.
# Shared so the SPEC FORMAT itself cannot drift between the two adapters;
# the per-runtime mount-target DECISION for role=nix stays in each adapter,
# not here.
dx_runtime_container_create_parse_volume_spec() {
    local spec="$1" rest
    case "$spec" in
        nix:*)
            DXE_VOLSPEC_ROLE=nix
            rest="${spec#nix:}"
            DXE_VOLSPEC_NAME="${rest%%:*}"
            DXE_VOLSPEC_TARGET=""
            DXE_VOLSPEC_MODE="${rest##*:}"
            ;;
        persist:*|bootstrap:*|git:*)
            DXE_VOLSPEC_ROLE="${spec%%:*}"
            rest="${spec#*:}"
            DXE_VOLSPEC_NAME="${rest%%:*}"
            rest="${rest#*:}"
            DXE_VOLSPEC_TARGET="${rest%%:*}"
            DXE_VOLSPEC_MODE="${rest##*:}"
            ;;
        *)
            echo "Error: unrecognized --volume spec '$spec' (expected nix:NAME:MODE or {persist,bootstrap,git}:NAME:TARGET:MODE)." >&2
            return 1
            ;;
    esac
    # This function's real output: read by each adapter's own
    # container_create renderer in a DIFFERENT file
    # (bin/lib/dx-runtime-apple.sh, bin/lib/dx-runtime-docker.sh) --
    # exported both because a child process may need them too and because
    # ShellCheck's per-file analysis cannot otherwise see the cross-file use
    # (SC2034).
    export DXE_VOLSPEC_ROLE DXE_VOLSPEC_NAME DXE_VOLSPEC_TARGET DXE_VOLSPEC_MODE
}

dx_runtime_container_create() { dx_runtime_dispatch container_create "$@"; }
dx_runtime_container_start() { dx_runtime_dispatch container_start "$@"; }
dx_runtime_container_stop() { dx_runtime_dispatch container_stop "$@"; }
dx_runtime_container_kill() { dx_runtime_dispatch container_kill "$@"; }
dx_runtime_container_delete() { dx_runtime_dispatch container_delete "$@"; }

# dx_runtime_container_owned <name> <verb> -- the ownership check (Astra
# F3, qnap-dxe-plan.md DQ6) bin/dx-create-container runs before treating an
# EXISTING same-named container as already provisioned: DX_RUNTIME=docker-ssh
# proves it via DQ6 labels (bin/lib/dx-runtime-docker-identity.sh's
# dx_runtime_docker_container_owned, also reused internally by that
# adapter's own container_start/stop/kill/delete before each real docker
# command); DX_RUNTIME=apple has no per-object labels at all (see
# dx-runtime-apple.sh's own comment on this) and is always this one host's
# own by construction, so its implementation is an unconditional success,
# not a placeholder for a future check.
dx_runtime_container_owned() { dx_runtime_dispatch container_owned "$@"; }

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

# dx_runtime_lock_acquire/_release/_path (Astra F4, WP6.5): the lifecycle
# lock bin/lib/dx-container.sh's dx_lifecycle_lock_acquire/_release use,
# under EITHER runtime -- unlike dx_runtime_docker_lock_audit/_release
# (bin/dx-lock's and bin/dx-status's own read-only surface, which never
# runs for DX_RUNTIME=apple at all, so those two names stay the narrow,
# reasoned exception already granted in
# tests/test_runtime_boundary_audit.sh), this needs a real dispatch for
# both, so it goes through the ordinary dx_runtime_dispatch here like every
# other dx_runtime_<op> contract operation, rather than either adapter's
# lock function being named directly outside its own file. _acquire prints
# the owner token it claimed (Docker: a minted host:pid:random:timestamp
# string; Apple: the local lock directory's own path); _release takes that
# same token back; _path (Apple's own deterministic lock directory path,
# computable without acquiring anything) exists only so a caller that must
# avoid capturing _acquire's stdout through a command substitution -- doing
# so would fork a subshell, and bin/lib/dx-host-util.sh's own
# dx_lock_acquire sets DXE_HELD_LOCK as a plain, never-exported shell
# variable that would not survive it -- can still fetch the token
# separately afterward. Docker-ssh has no local path of its own to expose
# through it (bin/lib/dx-runtime-docker-lock.sh's own dx_runtime_docker_lock_path
# stub explains why), so no caller ever dispatches to it under docker-ssh.
dx_runtime_lock_acquire() { dx_runtime_dispatch lock_acquire "$@"; }
dx_runtime_lock_release() { dx_runtime_dispatch lock_release "$@"; }
dx_runtime_lock_path() { dx_runtime_dispatch lock_path "$@"; }
