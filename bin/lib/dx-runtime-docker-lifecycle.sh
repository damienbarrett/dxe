#!/bin/bash
# Docker-over-SSH lifecycle: existence/state queries, container create (and
# its Docker-argv rendering of bin/lib/dx-runtime.sh's runtime-neutral
# vocabulary), start/stop/kill/delete, image build/delete, volume
# role/create/delete, the whole-operation destructive plan, volume usage
# reporting, exec/logs/export/run_ephemeral, and the capability table. One
# of the four files bin/lib/dx-runtime-docker.sh sources (see
# docs/refactor/decisions/D8-docker-adapter-history.md for the split's
# history); that file remains the facade every caller sources and
# dispatches through, and sources bin/lib/dx-runtime-docker-transport.sh
# and bin/lib/dx-runtime-docker-identity.sh before this file, so
# dx_runtime_docker_cli/require_bin/profile_id/verify_labels/*_labels are
# already defined by the time any function below actually runs.
#
# Safe to source: defines functions and constants only, no I/O, no command
# dispatch, no shell options, at import time (same contract as every other
# bin/lib/*.sh file).

# --- Queries (item 3) -------------------------------------------------------
#
# Existence/state queries use `inspect`'s exit status (structured, never
# table parsing): an inspect that fails means "does not exist" or "not
# reachable" -- both are reported as "false"/non-zero here, and a caller
# that needs to tell those apart calls dx_runtime_available first (the same
# convention dx_require_container_cli establishes for Apple). Raw *_list
# operations are, like their Apple counterparts, "raw text for human
# display" only (docs/refactor/runtime-boundary-inventory.md's own scoping
# for dx_runtime_image_list/dx_runtime_container_list): nothing in this
# adapter parses their output, so they use a --format that keeps the
# resource's name in the first column (matching Apple's own column-1-is-
# name table shape) rather than Docker's own default (image ID / container
# ID first), purely so an existing caller's column-anchored display habits
# keep working unmodified for either runtime.

dx_runtime_docker_image_exists() {
    dx_runtime_docker_cli image inspect "$1" >/dev/null 2>&1
}

# (docs/refactor/direct-volume-storage.md section 5.1): the runtime's own
# stable image identity, forwarded by
# bin/dx-create-container as DX_IMAGE_IDENTITY so the direct-volume guest
# can detect an image bump on a reused volume without reaching the image's
# own (hidden-under-the-mount) store. Structured, single-field query, the
# same shape tests/qnap/phase0-spike.sh already uses for its own base/tag
# digest comparison; Docker's template renders "sha256:<hex>" itself, no
# parsing needed on the controller.

dx_runtime_docker_image_identity() {
    dx_runtime_docker_cli image inspect --format '{{.Id}}' "$1"
}

dx_runtime_docker_image_list() {
    dx_runtime_docker_cli image ls "$@" --format 'table {{.Repository}}	{{.Tag}}	{{.ID}}	{{.CreatedSince}}	{{.Size}}'
}

dx_runtime_docker_volume_exists() {
    dx_runtime_docker_cli volume inspect "$1" >/dev/null 2>&1
}

# dx_runtime_volume_state's docker-ssh answer, from the same single
# `volume inspect`: success is present; a failure that says "no such volume"
# in any letter case (the CLI's "Error: No such volume: NAME", the daemon's
# "get NAME: no such volume") is absent; any other failure -- the daemon or
# the ssh connection down, permission denied -- is unknown, and its message
# is passed on as `dx:` lines, never an `Error:` line.
dx_runtime_docker_volume_state() {
    local err
    if err="$(dx_runtime_docker_cli volume inspect "$1" 2>&1 >/dev/null)"; then
        printf 'present\n'
        return 0
    fi
    case "$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')" in
        *"no such volume"*) printf 'absent\n'; return 0 ;;
    esac
    [ -z "$err" ] || printf '%s\n' "$err" | sed 's/^/dx: volume inspect: /' >&2
    printf 'unknown\n'
    return 1
}

dx_runtime_docker_container_exists() {
    dx_runtime_docker_cli container inspect "$1" >/dev/null 2>&1
}

dx_runtime_docker_container_running() {
    local state
    state="$(dx_runtime_docker_cli container inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" || return 1
    state="$(printf '%s\n' "$state" | tail -n1 | tr -d '\r')"
    [ "$state" = true ]
}

dx_runtime_docker_container_restart_count() {
    local count
    count="$(dx_runtime_docker_cli container inspect --format '{{.RestartCount}}' "$1" 2>/dev/null)" || return 1
    printf '%s\n' "$count" | tail -n1 | tr -d '\r'
}

# dx_runtime_container_state's docker-ssh answer (plans/do WP6.4), from ONE
# `container inspect --format {{.State.Running}}` (stdout and stderr read
# together): a last line of true is running, false is stopped; a failure that
# says "no such container" or "no such object" in any letter case is absent.
# Anything else -- the daemon or the ssh connection down, an answer that is
# neither true nor false, an empty name (no call) -- is unknown, non-zero, its
# message passed on as `dx:` lines, never an `Error:` line.
dx_runtime_docker_container_state() {
    local out="" rc=0
    if [ -z "${1:-}" ]; then
        rc=1
    else
        out="$(dx_runtime_docker_cli container inspect --format '{{.State.Running}}' "$1" 2>&1)" || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        case "$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')" in
            true) printf 'running\n'; return 0 ;;
            false) printf 'stopped\n'; return 0 ;;
        esac
    else
        case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" in
            *"no such container"* | *"no such object"*) printf 'absent\n'; return 0 ;;
        esac
    fi
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/dx: container inspect: /' >&2
    printf 'unknown\n'
    return 1
}

dx_runtime_docker_container_list() {
    # io.dxe.system is appended as a fourth column, keeping {{.Names}} first
    # so bin/dx-status's own
    # column-1-anchored `grep "^${DX_CONTAINER_NAME}[[:space:]]"` still works
    # unmodified.
    dx_runtime_docker_cli ps "$@" --format 'table {{.Names}}	{{.Image}}	{{.Status}}	{{.Label "io.dxe.system"}}'
}

# --- Lifecycle (item 4) -----------------------------------------------------
#
# Docker's CLI (confirmed against a real local Docker CLI, 27.x) agrees with
# Apple's own flag names/shapes for almost everything bin/'s entrypoints
# already send through the contract: -i/-t/-u for exec, --time for stop,
# -n for logs --tail, -f/--force for rm. So most operations below are a
# direct passthrough, with only the verb name changed where Apple and
# Docker genuinely differ (`container delete` vs `docker rm`).
#
# `container_create` renders bin/lib/dx-runtime.sh's runtime-neutral
# vocabulary (qnap-dxe-plan.md DQ2: "runtime-specific CLI syntax ... lives
# only in the adapter" -- see that file's own module comment for the full
# parameter list) into Docker's own create argv:
#   - the Nix volume mounts directly at /nix (DQ4's direct-volume mode);
#     no --cap-add at all (Apple's CAP_SYS_ADMIN exists only for the
#     GUEST bootstrap to reformat/remount its OWN staging volume, which
#     this mode skips entirely -- there is nothing here to drop, docker-ssh
#     simply never emits it);
#   - --cpus, never Docker's own -c (which means --cpu-shares, a different
#     unit entirely -- confirmed against a real local Docker CLI);
#   - --restart from DX_CONTAINER_RESTART_POLICY's value (Docker accepts
#     "no"/"unless-stopped" verbatim, no translation needed);
#   - the DQ6 labels, computed here (not passed by the caller -- they
#     depend on DX_REMOTE_HOST, which only this adapter interprets).
# The shared --publish "PORT:2222" spec (no bind address) is prepended
# with dx_runtime_docker_guest_ssh_address's own
# discovered Tailscale address before rendering it as Docker's -p flag --
# never loopback, never the LAN, never 0.0.0.0 (DQ5). A discovery/
# validation failure refuses before any remote mutation: no container is
# created with a malformed or missing publish spec.

# --- DQ6 labels -------------------------------------------------------
#
# Schema version for the label set itself (bumped only if the label KEYS
# or their meaning change, independent of DXE_CONFIG_SNAPSHOT_VERSION_CURRENT
# which versions the unrelated configuration-snapshot shape).
DXE_RUNTIME_DOCKER_LABEL_SCHEMA=1

# Populates DXE_RUNTIME_DOCKER_LABEL_ARGV with the five `--label k=v` pairs
# every docker-ssh-created resource carries (qnap-dxe-plan.md DQ6, plus
# io.dxe.system -- the guest system, so an image/container/volume/lock can
# never be mistaken for a different architecture). One line, not kcov's
# usual multi-line array-literal style:
# kcov's line-based instrumentation does not reliably attribute a hit to
# every continuation line of a multi-line array assignment (confirmed: the
# 4 continuation lines of an earlier draft never registered a hit despite
# this function running constantly), the same class of kcov limitation
# tests/run-coverage-linux.sh's own KCOV_SUBSHELL_TERMINATOR works around.
dx_runtime_docker_label_flags() {
    DXE_RUNTIME_DOCKER_LABEL_ARGV=(--label io.dxe.managed=true --label "io.dxe.schema=$DXE_RUNTIME_DOCKER_LABEL_SCHEMA" --label "io.dxe.profile=$(dx_runtime_docker_profile_id)" --label "io.dxe.role=$1" --label "io.dxe.system=${DX_GUEST_SYSTEM:?}")
}

# ",readonly" for MODE ro, nothing otherwise.
dx_runtime_docker_mount_ro_suffix() {
    [ "$1" != ro ] || printf ',readonly'
}

dx_runtime_docker_container_create() {
    dx_runtime_docker_require_bin >/dev/null || return 1
    local name="" image="" entrypoint_cmd="" flags=() entrypoint_args=() guest_addr="" prev="" arg
    # PREPASS: parse every --volume spec before the first runtime call, so a
    # malformed persist-dir path (':' or ',') is refused with nothing sent.
    for arg in "$@"; do
        if [ "$prev" = --volume ]; then
            dx_runtime_container_create_parse_volume_spec "$arg" || return 1
        fi
        prev="$arg"
    done
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --image) image="$2"; shift 2 ;;
            --volume)
                dx_runtime_container_create_parse_volume_spec "$2" || return 1
                case "$DXE_VOLSPEC_ROLE" in
                    persist-dir)
                        # No ownership proof and no host mutation: the
                        # directory is operator-owned (D-4/D-5), one --mount
                        # pair, never -v/--volume (a missing source would be
                        # silently created by -v).
                        flags+=(--mount "type=bind,source=$DXE_VOLSPEC_NAME,target=$DXE_VOLSPEC_TARGET$(dx_runtime_docker_mount_ro_suffix "$DXE_VOLSPEC_MODE")")
                        ;;
                    nix)
                        # Astra F3's "writable attachment" checkpoint: an
                        # EXISTING nix/persist/bootstrap volume is proven
                        # owned before this create ever mounts it rw into a
                        # new container -- container_ensure_volume already
                        # gates the common path (bin/dx-create-volumes
                        # running before bin/dx-create-container), but a
                        # caller that reaches this function directly, or
                        # whose profile drifted between the two steps,
                        # still gets the same proof here. An ABSENT volume
                        # needs no such proof (dx_runtime_docker_volume_create
                        # is what would label it, and that already refuses
                        # an unrecognized name on its own).
                        if dx_runtime_docker_volume_exists "$DXE_VOLSPEC_NAME"; then
                            dx_runtime_docker_volume_owned "$DXE_VOLSPEC_NAME" attach || return 1
                        fi
                        flags+=(--volume "$DXE_VOLSPEC_NAME:/nix:$DXE_VOLSPEC_MODE")
                        ;;
                    git)
                        # (qnap-dxe-plan.md DQ8; see D8 for the "git:
                        # volumes are Apple-only" decision this refuses
                        # under): a "git:" volume's own NAME field is a
                        # controller-local directory path (a bind mount),
                        # never a valid remote bind source over SSH --
                        # refuse here,
                        # before any remote mutation, regardless of how
                        # the caller reached this vocabulary (bin/dx-mount's
                        # own guard is the fail-fast path for the common
                        # case; this is the adapter-level backstop for any
                        # other caller, e.g. DX_GIT_MOUNT_SOURCE set
                        # directly and bin/dx-create-container run without
                        # going through bin/dx-mount at all).
                        dx_runtime_docker_capability bind_mounts || {
                            echo "Error: dx_runtime_docker_container_create: a git: (bind mount) volume is not supported: DX_RUNTIME=docker-ssh has no bind_mounts capability (qnap-dxe-plan.md DQ8)." >&2
                            return 1
                        }
                        flags+=(--volume "$DXE_VOLSPEC_NAME:$DXE_VOLSPEC_TARGET:$DXE_VOLSPEC_MODE")
                        ;;
                    # persist/bootstrap: the same "writable attachment"
                    # ownership proof as the nix branch above, for the
                    # other two configured named volumes.
                    *)
                        if dx_runtime_docker_volume_exists "$DXE_VOLSPEC_NAME"; then
                            dx_runtime_docker_volume_owned "$DXE_VOLSPEC_NAME" attach || return 1
                        fi
                        flags+=(--volume "$DXE_VOLSPEC_NAME:$DXE_VOLSPEC_TARGET:$DXE_VOLSPEC_MODE")
                        ;;
                esac
                shift 2
                ;;
            --env) flags+=(-e "$2"); shift 2 ;;
            --memory) flags+=(-m "$2"); shift 2 ;;
            --cpus) flags+=(--cpus "$2"); shift 2 ;;
            --publish)
                # bin/dx-create-container passes a neutral "PORT:2222" spec,
                # no bind address (DQ5); this is the one
                # place a docker-ssh profile's guest address is actually
                # rendered into a real Docker flag. A discovery/validation
                # failure here refuses the whole create -- never a container
                # published on the wrong address.
                guest_addr="$(dx_runtime_docker_guest_ssh_address)" || return 1
                flags+=(-p "$guest_addr:$2")
                shift 2
                ;;
            --restart-policy) flags+=(--restart "$2"); shift 2 ;;
            # (qnap-dxe-plan.md Phase 6 item 4): Docker's
            # own flag names, no translation needed -- see
            # bin/lib/dx-runtime.sh's vocabulary comment and
            # docs/refactor/docker-adapter-mapping.md section 4 for why.
            --health-cmd) flags+=(--health-cmd "$2"); shift 2 ;;
            --health-interval) flags+=(--health-interval "$2"); shift 2 ;;
            --health-retries) flags+=(--health-retries "$2"); shift 2 ;;
            --entrypoint-cmd) entrypoint_cmd="$2"; shift 2 ;;
            --entrypoint-arg) entrypoint_args+=("$2"); shift 2 ;;
            *) echo "Error: dx_runtime_docker_container_create: unknown parameter '$1'." >&2; return 1 ;;
        esac
    done
    [ -n "$name" ] || { echo "Error: dx_runtime_docker_container_create: --name is required." >&2; return 1; }
    [ -n "$image" ] || { echo "Error: dx_runtime_docker_container_create: --image is required." >&2; return 1; }
    dx_runtime_docker_label_flags container
    # "${arr[@]+"${arr[@]}"}" for flags/entrypoint_args (never DXE_RUNTIME_DOCKER_LABEL_ARGV,
    # which dx_runtime_docker_label_flags always populates with 5 elements):
    # bash 3.2 treats a zero-element array as unset under "set -u" -- see
    # dx_runtime_docker_exec's own module comment above for the full
    # reasoning and bin/lib/dx-runtime-apple.sh's container_create for the
    # same fix on the Apple side.
    # --hostname equals --name: Apple's `container create --name` also sets the
    # guest hostname, but Docker would use the short container ID (new on every
    # recreate), so the guest would differ between runtimes for no reason.
    dx_runtime_docker_cli create --name "$name" --hostname "$name" --entrypoint sh \
        "${flags[@]+"${flags[@]}"}" "${DXE_RUNTIME_DOCKER_LABEL_ARGV[@]}" \
        "$image" -c "$entrypoint_cmd" -- "${entrypoint_args[@]+"${entrypoint_args[@]}"}"
}

# Astra F3: start/stop/kill used to address the configured name directly,
# issuing the real docker command with no ownership check at all -- a
# foreign or unlabelled same-named container was started, stopped, or
# killed exactly like this profile's own. The container's name is always
# the LAST positional argument (the same "for name in "$@"; do :; done"
# idiom dx_runtime_docker_container_delete below already used, since a
# caller may prepend flags -- "--time N NAME" for stop). The ownership
# check runs BEFORE the real docker command is ever issued: on refusal,
# the fake/real docker command is never reached at all (proven at the
# transcript level in tests/test_docker_runtime_adapter.sh), not merely
# attempted and then failing.
dx_runtime_docker_container_start() {
    local name
    for name in "$@"; do :; done
    dx_runtime_docker_container_owned "$name" start || return 1
    dx_runtime_docker_cli start "$@"
}

dx_runtime_docker_container_stop() {
    local name
    for name in "$@"; do :; done
    dx_runtime_docker_container_owned "$name" stop || return 1
    dx_runtime_docker_cli stop "$@"
}

dx_runtime_docker_container_kill() {
    local name
    for name in "$@"; do :; done
    dx_runtime_docker_container_owned "$name" kill || return 1
    dx_runtime_docker_cli kill "$@"
}

# --- DQ6 label verification before mutation (item 5; Astra F3) ------------
#
# "An existing same-named unlabelled or differently labelled object is a
# collision, not an adoption candidate" (DQ6). container_start/stop/kill
# above and container_delete below all run
# dx_runtime_docker_container_owned/dx_runtime_docker_volume_owned
# (bin/lib/dx-runtime-docker-identity.sh) BEFORE the real docker command --
# Astra F3 found start/stop/kill addressed the configured name directly
# with no check at all, and that dx-destroy-container's own stop attempt
# could reach a foreign container before delete's (then only) check ever
# ran. bin/lib/dx-container.sh's container_ensure_volume (adoption of an
# EXISTING volume) and bin/dx-create-container's own "already exists"
# gate (adoption of an EXISTING container) run the identical check too, so
# there is now exactly one place -- dx_runtime_docker_resource_owned -- that
# decides ownership for every one of adopt/create/start/stop/kill/delete.
#
# Images are the one exception: qnap-dxe-plan.md Phase 0 found the NAS
# refuses a remote `docker build`, so image_build (above) never builds --
# it pulls and tags a pinned reference, and `docker tag` cannot attach a
# label (only a build or commit can). There is therefore no label DQ6
# could check for an image; image_delete's only available protection is
# the exact-name addressing its one caller (bin/dx-destroy-image) already
# provides. Documented here rather than silently pretended away.

# Apple's verb is "delete"; Docker's is "rm" -- otherwise identical flags
# (Apple --force, Docker -f/--force). The container name is always the
# last argument (bin/dx-destroy-container calls this as either
# "dx_runtime_container_delete NAME" or
# "dx_runtime_container_delete --force NAME").
dx_runtime_docker_container_delete() {
    local name
    for name in "$@"; do :; done
    dx_runtime_docker_container_owned "$name" delete || return 1
    dx_runtime_docker_cli rm "$@"
}

# The Containerfile's pinned base image reference. qnap-dxe-plan.md's
# Phase 0 outcome: the real NAS refuses `docker build` outright for its
# account ("QNAP's Docker wrapper creates a per-user build directory ...
# and refuses it there for a non-default administrator"). The Containerfile
# in this repository is, and must stay, a single "FROM <pinned-ref>@sha256:..."
# line -- the guest's actual content comes from the bootstrap volume, not
# image layers -- so docker-ssh's "build" instead pulls the pinned
# reference, then tags it as the configured image name. No remote build,
# no local build + save/load: never touches a remote build context
# directory at all. Fails closed with a clear message if the Containerfile
# ever contains anything beyond that one FROM line (a second stage, a
# RUN/COPY instruction, ...) rather than silently building only part of it
# or ignoring the rest.

dx_runtime_docker_base_image_ref() {
    local context_dir="$1" containerfile significant_lines from_line
    containerfile="$context_dir/Containerfile"
    [ -f "$containerfile" ] || { echo "Error: no Containerfile in $context_dir." >&2; return 1; }
    significant_lines="$(grep -vcE '^[[:space:]]*(#.*)?$' "$containerfile")"
    if [ "$significant_lines" != 1 ]; then
        echo "Error: $containerfile has $significant_lines significant line(s); the docker-ssh adapter only supports a Containerfile that is a single 'FROM <pinned-ref>' line (qnap-dxe-plan.md Phase 0: the NAS refuses a remote docker build, so this adapter pulls and tags the pinned base image instead of building one)." >&2
        return 1
    fi
    from_line="$(grep -vE '^[[:space:]]*(#.*)?$' "$containerfile")"
    case "$from_line" in
        FROM\ *)
            from_line="${from_line#FROM }"
            case "$from_line" in
                ''|*[[:space:]]*)
                    echo "Error: $containerfile's FROM line does not name a single image reference." >&2
                    return 1
                    ;;
            esac
            printf '%s' "$from_line"
            ;;
        *)
            echo "Error: $containerfile's only significant line is not a FROM instruction." >&2
            return 1
            ;;
    esac
}

# Parses the same "-t IMAGE CONTEXT_DIR" argv bin/dx-create-image already
# sends through the contract (dx_runtime_image_build -t "$DX_IMAGE"
# "$DX_CONTEXT_DIR") -- not a docker-ssh-specific shape, but the one
# existing caller's shape, which this adapter must accept unchanged.

dx_runtime_docker_image_build() {
    local image="" context_dir="" ref
    case "$1" in
        -t)
            [ "$#" -ge 3 ] || { echo "Error: dx_runtime_docker_image_build expected '-t IMAGE CONTEXT_DIR'." >&2; return 1; }
            image="$2"; context_dir="$3"
            ;;
        *)
            echo "Error: dx_runtime_docker_image_build only supports bin/dx-create-image's '-t IMAGE CONTEXT_DIR' shape (got: $*)." >&2
            return 1
            ;;
    esac
    ref="$(dx_runtime_docker_base_image_ref "$context_dir")" || return 1
    dx_runtime_docker_cli pull "$ref" || return 1
    dx_runtime_docker_cli tag "$ref" "$image"
}

# No label check possible (see this section's own module comment): images
# are never labelled under the pull+tag-only build design. The one caller
# (bin/dx-destroy-image) already addresses by exact configured name; that
# is the only protection available here.

dx_runtime_docker_image_delete() {
    dx_runtime_docker_cli image rm "$@"
}

# Role is derived from which configured volume name was passed -- the one
# caller (bin/lib/dx-container.sh's container_ensure_volume) only ever
# calls this with DX_NIX_VOLUME, DX_PERSIST_VOLUME, or DX_BOOTSTRAP_VOLUME
# (bin/dx-create-volumes, bin/dx-migrate-persist). Fails closed on any
# other name rather than creating an unlabelled volume.

dx_runtime_docker_volume_role() {
    case "$1" in
        "${DX_NIX_VOLUME:-dx-nix}") printf 'nix' ;;
        "${DX_PERSIST_VOLUME:-dx-persist}") printf 'persist' ;;
        "${DX_BOOTSTRAP_VOLUME:-dx-bootstrap}") printf 'bootstrap' ;;
        *) return 1 ;;
    esac
}

dx_runtime_docker_volume_create() {
    local role
    dx_runtime_docker_require_bin >/dev/null || return 1
    role="$(dx_runtime_docker_volume_role "$1")" || {
        echo "Error: dx_runtime_docker_volume_create: '$1' is not one of the configured DXE volumes (DX_NIX_VOLUME/DX_PERSIST_VOLUME/DX_BOOTSTRAP_VOLUME); refusing to create it unlabelled (qnap-dxe-plan.md DQ6)." >&2
        return 1
    }
    dx_runtime_docker_label_flags "$role"
    dx_runtime_docker_cli volume create "${DXE_RUNTIME_DOCKER_LABEL_ARGV[@]}" "$@"
}

# dx_runtime_volume_owned's docker-ssh implementation (bin/lib/
# dx-runtime.sh's dispatch; also this file's own shared entry point for
# volume_delete below): derives the DQ6 role from the configured volume
# name (nix/persist/bootstrap) and, if that resolves, checks ownership
# through dx_runtime_docker_resource_owned. Fails closed on an
# unrecognized name -- never guesses a role for an unconfigured volume.
dx_runtime_docker_volume_owned() {
    local name="$1" verb="$2" role
    role="$(dx_runtime_docker_volume_role "$name")" || {
        echo "Error: refusing to $verb volume '$name': not one of the configured DXE volumes (DX_NIX_VOLUME/DX_PERSIST_VOLUME/DX_BOOTSTRAP_VOLUME); refusing rather than guessing its role." >&2
        return 1
    }
    dx_runtime_docker_resource_owned volume "$name" "$role" "$verb"
}

dx_runtime_docker_volume_delete() {
    local name
    for name in "$@"; do :; done
    dx_runtime_docker_volume_owned "$name" delete || return 1
    dx_runtime_docker_cli volume rm "$@"
}

# --- Whole-operation destructive plan (item 7) -------
#
# The two functions above already verify DQ6 labels per resource, at
# DELETE time -- a collision refuses that one call, but a factory reset or
# volume-destroy sequence issuing several delete calls in a row could still
# destroy some resources successfully before refusing on a later one: a
# partial destroy, and the operator's typed confirmation was never shown
# the per-resource label state at all. qnap-dxe-plan.md Phase 6 item 7
# asks for more: an IMMUTABLE PLAN printed before ANY deletion, and the
# WHOLE operation refused -- zero delete calls reached -- if ANY one
# targeted resource fails its check.
#
# bin/dx-factory-reset and bin/dx-destroy-volumes reach this through
# bin/lib/dx-container.sh's runtime-neutral dx_destructive_plan_and_verify
# (a no-op under DX_RUNTIME=apple -- Apple has no DQ6 labels to check at
# all), rather than duplicating this file's own label-query internals
# outside the adapter boundary; that one call site is a narrow, reasoned
# exception in tests/test_runtime_boundary_audit.sh, the same shape
# already granted to bin/dx-lock/bin/dx-status's own read-only lock view --
# there is no dx_runtime_<op> contract equivalent to route through without
# inventing a new contract operation.
#
# Args: one "kind:name:role" triple per target resource (kind is
# "container" or "volume", matching the labels above's own role values).
# Prints the plan to stdout for every resource, existing or not, before
# returning -- a resource that does not exist at all is named but never
# label-checked (nothing to verify or delete, distinct from one that
# exists but is mislabelled). Returns non-zero, with every resource's
# state already printed and NO delete call issued by this function or its
# caller, if any EXISTING resource fails its label check.
dx_runtime_docker_destructive_plan_and_verify() {
    local bin spec kind rest name role fields ok=0
    bin="$(dx_runtime_docker_require_bin)" || return 1
    echo "Immutable plan (docker-ssh ownership proof, qnap-dxe-plan.md DQ6):"
    for spec in "$@"; do
        kind="${spec%%:*}"
        rest="${spec#*:}"
        name="${rest%%:*}"
        role="${rest#*:}"
        case "$kind" in
            container)
                if ! dx_runtime_docker_container_exists "$name"; then
                    echo "  container $name: does not exist -- nothing to verify or delete"
                    continue
                fi
                fields="$(dx_runtime_docker_container_labels "$bin" "$name")" || fields=""
                ;;
            volume)
                if ! dx_runtime_docker_volume_exists "$name"; then
                    echo "  volume $name: does not exist -- nothing to verify or delete"
                    continue
                fi
                fields="$(dx_runtime_docker_volume_labels "$bin" "$name")" || fields=""
                ;;
            *)
                echo "Error: dx_runtime_docker_destructive_plan_and_verify: unknown kind '$kind' (expected container or volume)." >&2
                return 1
                ;;
        esac
        echo "  $kind $name: labels=${fields:-<unreadable>}"
        if ! dx_runtime_docker_labels_owned "$role" "$fields"; then
            echo "Error: refusing to delete $kind '$name': it exists but is unlabelled or labelled for a different profile/role/schema/system (qnap-dxe-plan.md DQ6 -- this is a collision, not an adoption candidate)." >&2
            ok=1
        fi
    done
    return "$ok"
}

# (qnap-dxe-plan.md Phase 3 item 5): a capability-aware
# size report for bin/dx-reclaim. Docker has no host-side sparse image to
# measure (DQ4); `docker system df -v` is the structured, Docker-native
# usage query. Rather than requesting the whole `--format '{{json .}}'`
# blob and parsing it on the controller (no guaranteed jq -- this file's
# own module comment), the volume name is validated (it can only ever be
# one of the configured DXE volumes, already constrained to
# [A-Za-z0-9_.-] by bin/lib/dx-config.sh's own validation, so it is safe to
# interpolate into a Go template string) and Docker's own template engine
# does the filtering server-side, returning just the one matching volume's
# size as a plain scalar -- no JSON parsing needed on either side. The CLI's
# volume formatter exposes `.Size` as Docker's own human-readable string
# ("4.835MB", "0B", or "N/A" when the daemon has not computed it), NOT the
# API's raw `.UsageData.Size` byte count -- confirmed to fail against a
# real Container Station Docker (27.1.2) with "can't evaluate field
# UsageData in type *formatter.volumeContext". The human-readable string
# is printed verbatim,
# which is also what the Apple side's `du -sh` prints. "unknown" covers
# every way Docker cannot say: the query fails outright, the volume is
# absent from the report, or the size is empty/"N/A".

dx_runtime_docker_volume_usage() {
    local name output
    name="$1"
    output="$(dx_runtime_docker_cli system df -v --format "{{range .Volumes}}{{if eq .Name \"$name\"}}{{.Size}}{{end}}{{end}}" 2>/dev/null)" || {
        printf 'unknown\n'
        return 0
    }
    output="$(printf '%s\n' "$output" | tail -n1 | tr -d '\r')"
    case "$output" in
        ''|N/A|*[!A-Za-z0-9.]*) printf 'unknown\n' ;;
        *) printf '%s\n' "$output" ;;
    esac
}

# Exec with optional stdin/user/TTY, logs, export: a plain function call
# with no intermediate subshell or pipe of its own (dx_runtime_docker_ssh_exec
# -> dx_runtime_docker_ssh_raw -> a bare `ssh` invocation), so stdin and
# exit status pass through to the real remote `docker exec`/`logs`/`export`
# unchanged, exactly like the Apple adapter's own passthrough -- proven
# directly in tests/test_docker_runtime_adapter.sh the same way
# tests/test_sourceable_coverage.sh proves it for Apple. Docker's flag names
# agree with Apple's (-i/-t/-u for exec, -n for logs' --tail); no
# translation needed.
# (qnap-dxe-plan.md DQ8 item 5; docs/refactor/
# remote-aware-ssh.md section 5): "docker exec -it" requests a pty from
# the REMOTE Docker daemon, but the outer ssh transport carrying that
# request also needs its OWN pty allocation for the remote pty to be
# usable end to end -- until now nothing added one. Scans only the
# LEADING flag tokens (name/user/tty flags always precede the container
# name in every existing call, the same convention
# dx_runtime_apple_container_create's own flag parser already follows),
# so a command body that happens to contain the substring "-t" is never
# mistaken for a flag. bin/dx-enter is the only caller that ever passes
# -it; every other caller (dx-gc, dx-reclaim, dx-status, bin/lib/
# dx-backup.sh's -i phase, dx-sync-bootstrap) passes -i alone, -u alone,
# both, or neither, and must keep working exactly as before (the existing
# unidirectional-exec discipline) -- so the non-tty path below is
# byte-for-byte what this function already did.
#
# Forces pty allocation with "-tt" (two -t options), not a single "-t":
# OpenSSH's own manual is explicit that a single "-t" does not force
# allocation when the ssh client's own local stdin is not itself a real
# terminal (a script, a test harness, dx-enter driven non-interactively),
# while multiple "-t" options force it unconditionally -- matching
# "docker exec -it"'s own unconditional pty request. A single "-t" would
# make "dx-enter <cmd>" over docker-ssh depend on whether ITS OWN
# invocation happened to run under a real terminal, which is exactly the
# "must work non-interactively too" requirement.

dx_runtime_docker_exec() {
    local bin flags=() tty=false
    bin="$(dx_runtime_docker_require_bin)" || return 1
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -it|-ti|-t) tty=true; flags+=("$1"); shift ;;
            -i)         flags+=("$1"); shift ;;
            -u)         flags+=("$1" "$2"); shift 2 ;;
            *) break ;;
        esac
    done
    # "${flags[@]+"${flags[@]}"}", not a bare "${flags[@]}": bash 3.2 (this
    # Mac's own /bin/bash) treats a zero-element array as if it were unset
    # when expanded under "set -u" (fixed only in bash 4.4+), so a bare
    # exec call with no leading -i/-u/-t flags -- the common case -- would
    # abort every caller running under "set -u" (tests/test_helpers.sh
    # sets it for the whole suite) with "flags[@]: unbound variable". Same
    # idiom bin/dx-backup and bin/dx-restore already use for their own
    # possibly-empty arrays.
    if [ "$tty" = true ]; then
        local ssh_opts=() opt
        while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dx_runtime_docker_ssh_option_argv)"
        ssh_opts+=(-tt)
        ssh "${ssh_opts[@]}" "${DX_REMOTE_HOST:?}" "$(dx_runtime_docker_quote_argv "$bin" exec "${flags[@]+"${flags[@]}"}" "$@")"
    else
        dx_runtime_docker_cli exec "${flags[@]+"${flags[@]}"}" "$@"
    fi
}

dx_runtime_docker_logs() {
    dx_runtime_docker_cli logs "$@"
}

dx_runtime_docker_export() {
    dx_runtime_docker_cli export "$@"
}

# Ephemeral, no-persistent-container run. Apple's own retry loop
# (dx_runtime_apple_run_ephemeral) exists solely for Apple Container's own
# "no runtime client exists: container is stopped" race
# (docs/refactor/runtime-boundary.md); Docker over SSH has no documented
# equivalent, so no retry is carried over here -- if a later live gate or
# characterisation work surfaces a distinct Docker-side race, that is new
# evidence for a scoped retry then, not something to guess at now
# (docs/refactor/docker-adapter-mapping.md section 5).

dx_runtime_docker_run_ephemeral() {
    dx_runtime_docker_cli run "$@"
}

# --- Runtime capability queries (qnap-dxe-plan.md DQ2/DQ3/DQ4/DQ8) --------
#
# See docs/refactor/docker-adapter-mapping.md's capability table for why
# each answer is what it is. raw_nix_disk: no --
# bin/dx-nix-disk's sparse Apple raw-disk-image mechanism has no Docker
# equivalent at all (DQ8: "Apple-only; fail immediately with a clear
# capability message"). container_healthcheck
# (qnap-dxe-plan.md Phase 6 item 4): yes -- the one neutral create-time
# health flag; --health-cmd/--health-interval/--health-retries render as
# Docker's own real create flags (above). runtime_host_directories: yes --
# the persist-dir: role renders as --mount type=bind (plans/do D-5).

dx_runtime_docker_capability() {
    case "$1" in
        direct_named_volume_mounts) return 0 ;;
        bind_mounts) return 1 ;;
        # runtime_host_directories: the adapter can bind an operator-owned
        # host directory as /persist (the persist-dir: role, plans/do D-4/D-5),
        # which bind_mounts (the dx-mount/git: host-folder kind) stays off for.
        runtime_host_directories) return 0 ;;
        restart_policy) return 0 ;;
        host_filesystem_reclamation) return 1 ;;
        raw_nix_disk) return 1 ;;
        container_healthcheck) return 0 ;;
        # bin/dx-usage-service drives the guest's s6 tree (DX_USAGE_SERVICE=on)
        # through exec; Apple has no such mode, so it answers no.
        usage_service) return 0 ;;
        *) echo "Error: unknown runtime capability '$1'." >&2; return 2 ;;
    esac
}


# dx_runtime_container_mounts <name> -- one `type|source|destination|rw` line
# per mount (plans/do D-6). A named volume reports its VOLUME NAME as the
# source, a bind its host path. One remote call through the transport; the
# reply has CR and blank lines stripped. A missing container is non-zero with
# no output.
dx_runtime_docker_container_mounts() {
    local out
    out="$(dx_runtime_docker_cli container inspect --format '{{range .Mounts}}{{.Type}}|{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}|{{.Destination}}|{{if .RW}}rw{{else}}ro{{end}}{{println}}{{end}}' "$1" 2>/dev/null)" || return 1
    printf '%s\n' "$out" | tr -d '\r' | awk 'NF'
}

# NAS directory operations (WP4.2; plan D-6; spec R15-R17). Each operation is
# exactly one ssh call through dx_runtime_docker_ssh_exec running
#   sh -c <constant SCRIPT> sh <data words...>
# so the data (root, guest, path, sentinel) is only ever positional "$@" in a
# fixed single-line POSIX program, never interpolated into it. The scripts use
# only POSIX/busybox tools, no newline and no single quote. The marker text
# is validated here with dx_persist_marker_parse and travels on stdin.

# $1 ROOT, $2 GUEST, $3 sentinel (empty = none). Reports facts only.
DX_RUNTIME_DOCKER_HOST_DIR_PROBE_SCRIPT='unset CDPATH; cd -P -- "$1" 2>/dev/null || { echo "dx: not a directory: $1" >&2; exit 1; }; r=$(pwd -P) || exit 1; mt=unknown; if [ -n "$3" ]; then mt=no; if [ -f "$r/$3" ] && [ ! -L "$r/$3" ]; then mt=yes; fi; fi; p="$r/dxe/$2/persist"; k="$p/.dxe-persist-dir"; mk=absent; if [ -L "$r/dxe" ] || [ -L "$r/dxe/$2" ] || [ -L "$p" ]; then st=symlink; elif [ -d "$p" ]; then l=$(ls -A -- "$p") || { echo "dx: cannot list: $p" >&2; exit 1; }; if [ -n "$l" ]; then st=nonempty; else st=empty; fi; if [ -f "$k" ] && [ ! -L "$k" ]; then mk=present; fi; elif [ -e "$p" ]; then echo "dx: not a directory: $p" >&2; exit 1; else st=absent; fi; printf "root=%s\nmounted=%s\nstate=%s\nmarker=%s\n" "$r" "$mt" "$st" "$mk"; if [ "$mk" = present ]; then cat -- "$k"; fi'

# The marker step shared by create and marker_write, run with the target
# directory as cwd: the slot may be replaced only if missing or a regular file;
# a temp file in the directory, then ONE mv onto the marker; on failure only
# that temp file is removed.
DX_RUNTIME_DOCKER_HOST_DIR_MARKER_TAIL='s=.dxe-persist-dir; if [ -L "$s" ] || { [ -e "$s" ] && [ ! -f "$s" ]; }; then echo "dx: marker slot is not a regular file: $s" >&2; exit 1; fi; t=$(mktemp ./.dxe-persist-dir.XXXXXX) || exit 1; if cat >"$t" && chmod 0644 "$t" && mv -- "$t" "$s"; then exit 0; fi; rm -f -- "$t"; exit 1'

# $1 ROOT, $2 GUEST; marker bytes on stdin. Creates exactly dxe/$2/persist
# (plain mkdir of the leaf, then the marker step) holding the marker.
DX_RUNTIME_DOCKER_HOST_DIR_CREATE_SCRIPT='unset CDPATH; cd -P -- "$1" 2>/dev/null || { echo "dx: not a directory: $1" >&2; exit 1; }; g="dxe/$2"; p="$g/persist"; if [ -L dxe ] || [ -L "$g" ]; then echo "dx: refusing a symlinked path: $g" >&2; exit 1; fi; if [ -e "$p" ] || [ -L "$p" ]; then echo "dx: exists: $p" >&2; exit 1; fi; if [ ! -d dxe ]; then mkdir -- dxe || exit 1; fi; if [ ! -d "$g" ]; then mkdir -- "$g" || exit 1; fi; mkdir -- "$p" || exit 1; cd -P -- "$p" || exit 1; '"$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_TAIL"

# $1 PATH (the persist directory); marker bytes on stdin. Temp file in PATH,
# then mv onto the marker; a failed mv leaves the old marker and no temp file.
DX_RUNTIME_DOCKER_HOST_DIR_MARKER_WRITE_SCRIPT='unset CDPATH; if [ -L "$1" ] || [ ! -d "$1" ]; then echo "dx: not a directory: $1" >&2; exit 1; fi; cd -P -- "$1" || exit 1; '"$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_TAIL"

DX_RUNTIME_DOCKER_HOST_DIR_USAGE_SCRIPT='unset CDPATH; du -sk -- "$1"'

# dx_runtime_docker_host_dir_marker_stream TEXT: the marker bytes -- TEXT plus
# exactly one trailing newline -- after proving TEXT is a valid marker.
dx_runtime_docker_host_dir_marker_stream() {
    local nl=$'\n'
    printf '%s\n' "$1" | dx_persist_marker_parse || return 1
    if [ "${1%"$nl"}" = "$1" ]; then
        printf '%s\n' "$1"
    else
        printf '%s' "$1"
    fi
}

# dx_runtime_docker_host_dir_guest_ok GUEST: the guest is a path component of
# the derived directory, so it must be a plain marker-class name.
dx_runtime_docker_host_dir_guest_ok() {
    dx_persist_marker_valid_name "$1" && return 0
    echo "Error: invalid guest name for the NAS directory: $1" >&2
    return 1
}

dx_runtime_docker_host_dir_operand_ok() {
    case "$1" in
        ""|-) echo "Error: refusing an empty or '-' NAS path." >&2; return 1 ;;
    esac
}

dx_runtime_docker_host_dir_probe() {
    dx_runtime_docker_host_dir_operand_ok "$1" || return 1
    dx_runtime_docker_host_dir_guest_ok "$2" || return 1
    dx_runtime_docker_ssh_exec sh -c "$DX_RUNTIME_DOCKER_HOST_DIR_PROBE_SCRIPT" sh "$1" "$2" "${DX_PERSIST_HOST_MOUNT_SENTINEL:-}"
}

dx_runtime_docker_host_dir_create() {
    local stream
    dx_runtime_docker_host_dir_operand_ok "$1" || return 1
    dx_runtime_docker_host_dir_guest_ok "$2" || return 1
    stream="$(dx_runtime_docker_host_dir_marker_stream "$3" && printf x)" || return 1
    stream="${stream%x}"
    printf '%s' "$stream" | dx_runtime_docker_ssh_exec sh -c "$DX_RUNTIME_DOCKER_HOST_DIR_CREATE_SCRIPT" sh "$1" "$2"
}

dx_runtime_docker_host_dir_marker_write() {
    local stream
    dx_runtime_docker_host_dir_operand_ok "$1" || return 1
    stream="$(dx_runtime_docker_host_dir_marker_stream "$2" && printf x)" || return 1
    stream="${stream%x}"
    printf '%s' "$stream" | dx_runtime_docker_ssh_exec sh -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_WRITE_SCRIPT" sh "$1"
}

dx_runtime_docker_host_dir_usage() {
    dx_runtime_docker_host_dir_operand_ok "$1" || return 1
    dx_runtime_docker_ssh_exec sh -c "$DX_RUNTIME_DOCKER_HOST_DIR_USAGE_SCRIPT" sh "$1"
}

# rsync operations (WP6.2/WP6.2b; plan D-10 as revised and clarified 2026-10-11;
# spec R31, R32). QTS ships rsync 3.0.7 and the NAS account is not root, so
# rsync runs INSIDE a one-off container on the NAS (root via Docker). $DX_IMAGE
# is only the bare nix base: the modern rsync lives in the guest's nix volume
# (root profile, installed from bootstrapEssentials at boot), mounted read-only
# at /nix after that volume's own DQ6 check. Every docker call goes through
# dx_runtime_docker_cli, so paths are only ever quoted argv words.
DX_RUNTIME_DOCKER_RSYNC_BIN=/nix/var/nix/profiles/per-user/root/profile/bin/rsync

# dx_runtime_docker_rsync_nix_check: the nix volume (configuration only, no
# fallback name) must be this profile's, role nix; sets DX_RSYNC_NIX_VOLUME.
dx_runtime_docker_rsync_nix_check() {
    DX_RSYNC_NIX_VOLUME="${DX_NIX_VOLUME-}"
    dx_runtime_docker_volume_owned "$DX_RSYNC_NIX_VOLUME" "run rsync from"
}

# Facts from `rsync --version` on stdin, one per line: version=N.N.N (or
# nothing when no version line exists), then hard_links, acls, xattrs as
# yes/no. A capability counts only as an exact comma-separated token between
# "Capabilities:" and "Optimizations:"; "hard links" is the older spelling.
DX_RUNTIME_DOCKER_RSYNC_FACTS_AWK='$1 == "rsync" && $2 == "version" && v == "" && $3 ~ /^[0-9]+[.][0-9]+([.][0-9]+)?$/ { v = $3 } /^Optimizations:/ { on = 0 } on { caps = caps "," $0 } /^Capabilities:/ { on = 1; caps = caps "," substr($0, 14) } END { n = split(caps, t, ","); for (i = 1; i <= n; i++) { s = t[i]; gsub(/^[ \t]+|[ \t]+$/, "", s); if (s == "hardlinks" || s == "hard links") hl = "yes"; if (s == "ACLs") acl = "yes"; if (s == "xattrs") xa = "yes" } if (v != "") print "version=" v; print "hard_links=" (hl == "yes" ? "yes" : "no"); print "acls=" (acl == "yes" ? "yes" : "no"); print "xattrs=" (xa == "yes" ? "yes" : "no") }'

# dx_runtime_docker_rsync_options_parse OPTION... -> sets DX_RSYNC_ACL/_XATTR
# (yes|no); anything but -A / -X is a usage error (the caller prints it).
dx_runtime_docker_rsync_options_parse() {
    local opt
    DX_RSYNC_ACL=no
    DX_RSYNC_XATTR=no
    for opt in "$@"; do
        case "$opt" in
            -A) DX_RSYNC_ACL=yes ;;
            -X) DX_RSYNC_XATTR=yes ;;
            *) return 1 ;;
        esac
    done
}

# dx_runtime_docker_rsync_gap FACTS ACL_NEEDED XATTR_NEEDED: print the first
# missing requirement (naming only that one) and return 1, or return 0.
dx_runtime_docker_rsync_gap() {
    local facts="$1" version major rest minor
    version="$(sed -n 's/^version=//p' <<<"$facts")"
    major="${version%%.*}"
    rest="${version#*.}"
    minor="${rest%%.*}"
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 1 ]; }; then
        echo "Error: rsync $version in the guest's nix volume is below 3.1 (the migration needs nanosecond mtimes)." >&2
        return 1
    fi
    if ! grep -Fqx hard_links=yes <<<"$facts"; then
        echo "Error: rsync $version in the guest's nix volume lacks hard links support." >&2
        return 1
    fi
    if [ "$2" = yes ] && ! grep -Fqx acls=yes <<<"$facts"; then
        echo "Error: rsync $version in the guest's nix volume lacks ACLs support (needed here)." >&2
        return 1
    fi
    if [ "$3" = yes ] && ! grep -Fqx xattrs=yes <<<"$facts"; then
        echo "Error: rsync $version in the guest's nix volume lacks xattrs support (needed here)." >&2
        return 1
    fi
}

# dx_runtime_docker_host_rsync_check [-A] [-X]
dx_runtime_docker_host_rsync_check() {
    local out facts rc=0
    dx_runtime_docker_rsync_options_parse "$@" || {
        echo "Usage: dx_runtime_host_rsync_check [-A] [-X]" >&2
        return 1
    }
    dx_runtime_docker_rsync_nix_check || return 1
    out="$(dx_runtime_docker_cli run --rm --network none --user 0:0 --pull never -v "$DX_RSYNC_NIX_VOLUME:/nix:ro" --entrypoint "$DX_RUNTIME_DOCKER_RSYNC_BIN" "${DX_IMAGE:?}" --version)" || rc=$?
    if [ "$rc" -eq 127 ]; then
        echo "Error: rsync is not in the guest's nix volume '$DX_RSYNC_NIX_VOLUME'; boot the guest once on the current image so its essentials include rsync." >&2
        return 1
    elif [ "$rc" -ne 0 ]; then
        echo "Error: could not run rsync from the guest's nix volume '$DX_RSYNC_NIX_VOLUME' on the NAS." >&2
        return 1
    fi
    facts="$(awk "$DX_RUNTIME_DOCKER_RSYNC_FACTS_AWK" <<<"$out")"
    if ! grep -Fq version= <<<"$facts"; then
        echo "Error: could not parse the rsync version from the image's output." >&2
        return 1
    fi
    dx_runtime_docker_rsync_gap "$facts" "$DX_RSYNC_ACL" "$DX_RSYNC_XATTR" || return 1
    printf '%s\n' "$facts"
}

# dx_runtime_docker_rsync_dir_ok DIR: an absolute NAS path that is neither "/"
# nor able to carry extra --mount options (",") or a second line.
dx_runtime_docker_rsync_dir_ok() {
    local nl=$'\n'
    case "$1" in
        /) : ;;
        /*,*|*"$nl"*) : ;;
        /*) return 0 ;;
    esac
    echo "Error: refusing the rsync directory '$1': it must be an absolute path other than / without a comma or newline." >&2
    return 1
}

# dx_runtime_docker_host_rsync forward|reverse VOLUME DIR [-A] [-X]
dx_runtime_docker_host_rsync() {
    local direction="${1:-}" volume="${2:-}" dir="${3:-}" extra=() mounts=()
    if [ "$#" -lt 3 ]; then
        echo "Usage: dx_runtime_host_rsync forward|reverse VOLUME DIR [-A] [-X]" >&2
        return 1
    fi
    shift 3
    case "$direction" in
        forward) mounts=(-v "$volume:/src:ro" --mount "type=bind,source=$dir,target=/dst") ;;
        reverse) mounts=(--mount "type=bind,source=$dir,target=/src,readonly" -v "$volume:/dst") ;;
        *) echo "Error: unknown rsync direction '$direction' (forward or reverse)." >&2; return 1 ;;
    esac
    dx_runtime_docker_rsync_options_parse "$@" || {
        echo "Error: unsupported rsync option (only -A and -X are accepted)." >&2
        return 1
    }
    if [ "$DX_RSYNC_ACL" = yes ]; then extra+=(-A); fi
    if [ "$DX_RSYNC_XATTR" = yes ]; then extra+=(-X); fi
    dx_runtime_docker_rsync_dir_ok "$dir" || return 1
    if [ "$volume" = "${DX_NIX_VOLUME-}" ]; then
        echo "Error: refusing to copy with volume '$volume': it is the guest's nix volume, already mounted at /nix (the persist volume is required)." >&2
        return 1
    fi
    if [ "$volume" = "${DX_BOOTSTRAP_VOLUME-}" ]; then
        echo "Error: refusing to copy with volume '$volume': it is the guest's bootstrap volume, never a copy's source or target (the persist volume is required)." >&2
        return 1
    fi
    dx_runtime_docker_volume_owned "$volume" copy || return 1
    dx_runtime_docker_rsync_nix_check || return 1
    dx_runtime_docker_cli run --rm --network none --user 0:0 --pull never -v "$DX_RSYNC_NIX_VOLUME:/nix:ro" "${mounts[@]}" --entrypoint "$DX_RUNTIME_DOCKER_RSYNC_BIN" "${DX_IMAGE:?}" \
        -aH --numeric-ids "${extra[@]+"${extra[@]}"}" \
        --exclude=/.dxe-persist-dir '--exclude=._*' /src/ /dst/
}

# Inventory operations (WP6.3; plan D-10; spec R37). Read-only: the volume is
# read by a one-off container that mounts it ":ro" with no network, and the
# share root's free space by one `df` on the NAS. The container script is POSIX
# sh in ONE line (kcov counts every line of a multi-line literal) and prints
# tagged key=value lines; it computes everything first and prints last, so a
# failing find/du/df exits non-zero without status=ok (never a partial number).
# Counts use `-exec printf ".%.0s" {} +` and then the length of the dots, so a
# name containing a newline is still one entry. It works from "." after a cd
# (relative paths need no prefix stripping that a path's own characters could
# disturb). The script holds no single quote, so the whole text is one
# single-quoted bash literal.
DX_RUNTIME_DOCKER_VOLUME_INVENTORY_SCRIPT='export LC_ALL=C; cd -- "$1" || exit 1; t=$(df -P -k .) || exit 1; set -- $(printf "%s\n" "$t" | tail -n 1); dt=$2; da=$4; s=$(du -sk .) || exit 1; s=${s%%[!0-9]*}; e=$(find . -mindepth 1 -exec printf ".%.0s" {} +) || exit 1; h=$(find . -mindepth 1 ! -type d -links +1 -exec printf ".%.0s" {} +) || exit 1; ac=$(find . -mindepth 1 -name "._*" -exec printf ".%.0s" {} +) || exit 1; al=$(find . -mindepth 1 -name "._*" -print) || exit 1; al=$(printf "%s\n" "$al" | sed "s|^\./||" | sort); sc=$(find . -mindepth 1 \( -type p -o -type s -o -type b -o -type c \) -exec printf ".%.0s" {} +) || exit 1; sl=$(find . -mindepth 1 \( -type p -o -type s -o -type b -o -type c \) -print) || exit 1; sl=$(printf "%s\n" "$sl" | sed "s|^\./||" | sort); acl=unknown; if command -v getfacl >/dev/null 2>&1; then a=$(getfacl -R -s -p . 2>/dev/null) && acl=$(printf "%s\n" "$a" | grep -c "^# file:"); fi; xa=unknown; if command -v getfattr >/dev/null 2>&1; then a=$(getfattr -R -h -d -m - . 2>/dev/null) && xa=$(printf "%s\n" "$a" | grep -c "^# file:"); fi; printf "df_total_kb=%s\ndf_avail_kb=%s\nsize_kb=%s\nentries=%s\nhardlinks=%s\nappledouble=%s\n" "$dt" "$da" "$s" "${#e}" "${#h}" "${#ac}"; if [ -n "$al" ]; then printf "%s\n" "$al" | sed "s/^/apple=/"; fi; printf "special=%s\n" "${#sc}"; if [ -n "$sl" ]; then printf "%s\n" "$sl" | sed "s/^/special_path=/"; fi; printf "acl=%s\nxattr=%s\nstatus=ok\n" "$acl" "$xa"'

# $1 ROOT: prints fs=, total_kb=, avail_kb= (KiB) of the filesystem holding it.
DX_RUNTIME_DOCKER_HOST_DIR_FREE_SCRIPT='t=$(df -P -k -- "$1") || exit 1; set -- $(printf "%s\n" "$t" | tail -n 1); printf "fs=%s\ntotal_kb=%s\navail_kb=%s\n" "$1" "$2" "$4"'

# dx_runtime_docker_volume_inventory VOLUME
dx_runtime_docker_volume_inventory() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: dx_runtime_volume_inventory VOLUME" >&2
        return 1
    fi
    dx_runtime_docker_volume_owned "$1" inventory || return 1
    dx_runtime_docker_cli run --rm --network none --user 0:0 --pull never -v "$1:/v:ro" --entrypoint sh "${DX_IMAGE:?}" \
        -c "$DX_RUNTIME_DOCKER_VOLUME_INVENTORY_SCRIPT" sh /v
}

# dx_runtime_docker_host_dir_inventory DIR (WP6.5): the same inventory of a
# host DIRECTORY on the NAS (the rollback's source), with the very script the
# volume inventory runs -- one script for both, so its bare-image rule covers
# both. DIR is bound read-only at /v with --mount (never -v, which would
# create a missing path), so it must be absolute, not "/", and free of ","
# (another mount option) and newlines. The checks before the one docker call
# print a `dx:` reason (status 1, no call); the container's stdout, stderr and
# status pass through.
dx_runtime_docker_host_dir_inventory() {
    local nl=$'\n' why=""
    [ "$#" -eq 1 ] || why="expected one DIR"
    case "${1-}" in
        / | "" | [!/]* | *,* | *"$nl"*) why="${why:-the directory '${1-}' cannot be bound: it must be an absolute path other than / without ',' or a newline}" ;;
    esac
    [ -n "${DX_IMAGE:-}" ] || why="${why:-no DX_IMAGE to run the one-off container from}"
    if [ -n "$why" ]; then
        echo "dx: refusing to read the NAS directory: $why" >&2
        return 1
    fi
    dx_runtime_docker_cli run --rm --network none --user 0:0 --pull never \
        --mount "type=bind,source=$1,target=/v,readonly" --entrypoint sh "$DX_IMAGE" \
        -c "$DX_RUNTIME_DOCKER_VOLUME_INVENTORY_SCRIPT" sh /v
}

# dx_runtime_docker_host_dir_free ROOT
dx_runtime_docker_host_dir_free() {
    dx_runtime_docker_host_dir_operand_ok "${1-}" || return 1
    dx_runtime_docker_ssh_exec sh -c "$DX_RUNTIME_DOCKER_HOST_DIR_FREE_SCRIPT" sh "$1"
}

# Establishing a directory (WP4.4; spec R15, R18; plans/do D-3, D-10) needs
# root on the NAS -- the new directory belongs to the guest's dx user, and
# the management SSH account is not root -- so it runs in ONE one-off
# container from $DX_IMAGE: --user 0:0, no network, never pulled, the share
# root bound with --mount (never -v, which would create a missing root) at
# this target. The script reads everything from "$@": $1 the bind target,
# $2 GUEST, $3 MODE, $4 OWNER, $5 the mount sentinel; the marker bytes come
# on stdin. In order it: refuses unless the sentinel is a regular file at
# the root (the share may have been unmounted since the probe); refuses a
# symlink at dxe, dxe/GUEST or the leaf; for create, refuses a leaf that
# exists in any form, makes the missing parents (never chowned or chmodded)
# and the leaf; for adopt and fresh-start, needs the leaf to be a directory
# with no entries at all; then chowns the leaf to OWNER and sets mode 0755;
# and writes the marker last through the shared marker step (temp file, one
# mv). A refusal writes nothing; a later failure leaves the leaf empty and
# unmarked, which the next dx-create-volumes adopts.
DX_RUNTIME_DOCKER_HOST_DIR_BIND_TARGET=/dxe-share
DX_RUNTIME_DOCKER_HOST_DIR_ESTABLISH_SCRIPT='unset CDPATH; umask 022; cd -P -- "$1" || exit 1; m="$5"; if [ ! -f "$m" ] || [ -L "$m" ]; then echo "dx: the share does not look mounted: no sentinel file $m at its root" >&2; exit 1; fi; g="dxe/$2"; p="$g/persist"; if [ -L dxe ] || [ -L "$g" ] || [ -L "$p" ]; then echo "dx: refusing a symlinked path: $p" >&2; exit 1; fi; case "$3" in create) if [ -e "$p" ]; then echo "dx: exists: $p" >&2; exit 1; fi; if [ ! -d dxe ]; then mkdir -- dxe || exit 1; fi; if [ ! -d "$g" ]; then mkdir -- "$g" || exit 1; fi; mkdir -- "$p" || exit 1 ;; adopt | fresh-start) if [ ! -d "$p" ]; then echo "dx: not a directory: $p" >&2; exit 1; fi; l=$(ls -A -- "$p") || exit 1; if [ -n "$l" ]; then echo "dx: not empty: $p" >&2; exit 1; fi ;; *) echo "dx: unknown mode: $3" >&2; exit 1 ;; esac; chown "$4" "$p" || exit 1; chmod 0755 "$p" || exit 1; cd -P -- "$p" || exit 1; '"$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_TAIL"

# dx_runtime_docker_host_dir_establish_ok MODE ROOT GUEST OWNER: the checks
# made before establish's one docker call. ROOT becomes part of a --mount
# option, so it must be absolute and free of ',' (another option) and
# newlines; OWNER is UID:GID in digits. Each reason is a `dx:` line, so the
# caller's own Error line is the only one.
dx_runtime_docker_host_dir_establish_ok() {
    local nl=$'\n' why="" owner=bad
    case "$1" in
        create | adopt | fresh-start) : ;;
        *) why="unknown mode '$1' (expected create, adopt or fresh-start)" ;;
    esac
    case "$2" in
        "" | [!/]* | *,* | *"$nl"*) why="${why:-the share root '$2' cannot be bound: it must be an absolute path without ',' or a newline}" ;;
    esac
    dx_persist_marker_valid_name "$3" || why="${why:-invalid guest name for the NAS directory: $3}"
    case "$4" in
        *[!0-9:]* | *:*:*) : ;;
        [0-9]*:[0-9]*) owner=ok ;;
    esac
    [ "$owner" = ok ] || why="${why:-the owner '$4' is not UID:GID in digits}"
    [ -n "${DX_PERSIST_HOST_MOUNT_SENTINEL:-}" ] || why="${why:-no DX_PERSIST_HOST_MOUNT_SENTINEL, so nothing would prove the share is mounted}"
    [ -n "${DX_IMAGE:-}" ] || why="${why:-no DX_IMAGE to run the one-off container from}"
    [ -n "$why" ] || return 0
    echo "dx: refusing to establish the NAS directory: $why" >&2
    return 1
}

dx_runtime_docker_host_dir_establish() {
    local stream
    dx_runtime_docker_host_dir_establish_ok "$1" "$2" "$3" "$4" || return 1
    stream="$(dx_runtime_docker_host_dir_marker_stream "$5" && printf x)" || return 1
    stream="${stream%x}"
    printf '%s' "$stream" | dx_runtime_docker_cli run --rm -i --network none --user 0:0 --pull never \
        --mount "type=bind,source=$2,target=$DX_RUNTIME_DOCKER_HOST_DIR_BIND_TARGET" \
        --entrypoint sh "$DX_IMAGE" -c "$DX_RUNTIME_DOCKER_HOST_DIR_ESTABLISH_SCRIPT" sh \
        "$DX_RUNTIME_DOCKER_HOST_DIR_BIND_TARGET" "$3" "$1" "$4" "$DX_PERSIST_HOST_MOUNT_SENTINEL" >&2
}

# Setting the marker during a migration (WP6.4; plans/do D-3; spec R16, R35)
# needs root on the NAS for the same reason as establish, so it is ONE
# one-off container from $DX_IMAGE with the share root bound at the same
# target. It is a compare-and-set: the script reads everything from "$@" --
# $1 the bind target, $2 GUEST, $3 EXPECTED_STATE, $4 SOURCE (the new marker's
# source volume, "" for none) -- and the new marker bytes from stdin. It
# refuses, writing nothing, unless dxe, dxe/GUEST and the leaf are no symlinks
# and the leaf is a directory; the marker is a regular file (no symlink); and
# its guest=, state= and source-volume= lines are exactly GUEST, EXPECTED_STATE
# and SOURCE (one each; no source-volume line when SOURCE is ""). Then the
# shared marker step (temp file, one mv), and no chown. $DX_IMAGE is the bare
# nix base (no sed, no awk), so the script uses only sh built-ins and the
# coreutils of the marker step (mktemp, cat, chmod, mv, rm).
DX_RUNTIME_DOCKER_HOST_DIR_MARKER_SET_SCRIPT='unset CDPATH; umask 022; cd -P -- "$1" || exit 1; g="dxe/$2"; p="$g/persist"; if [ -L dxe ] || [ -L "$g" ] || [ -L "$p" ] || [ ! -d "$p" ]; then echo "dx: not a real directory: $p" >&2; exit 1; fi; cd -P -- "$p" || exit 1; if [ -L .dxe-persist-dir ] || [ ! -f .dxe-persist-dir ]; then echo "dx: no marker file in $p" >&2; exit 1; fi; ng=0; ns=0; nv=0; bad=0; while IFS= read -r l || [ -n "$l" ]; do case "$l" in guest=*) if [ "$l" = "guest=$2" ]; then ng=$((ng + 1)); else bad=1; fi ;; state=*) if [ "$l" = "state=$3" ]; then ns=$((ns + 1)); else bad=1; fi ;; source-volume=*) if [ -n "$4" ] && [ "$l" = "source-volume=$4" ]; then nv=$((nv + 1)); else bad=1; fi ;; esac; done <.dxe-persist-dir || exit 1; if [ -n "$4" ] && [ "$nv" -ne 1 ]; then bad=1; fi; if [ "$bad" -ne 0 ] || [ "$ng" -ne 1 ] || [ "$ns" -ne 1 ]; then echo "dx: the marker in $p is not $3 for this guest and source volume; nothing was changed" >&2; exit 1; fi; '"$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_TAIL"

# dx_runtime_docker_host_dir_marker_set ROOT GUEST EXPECTED_STATE MARKER_TEXT.
# The checks before its one docker call print a `dx:` reason, so the caller's
# own Error line is the only one: ROOT becomes part of a --mount option
# (absolute, no ',' or newline); MARKER_TEXT must be a valid marker for GUEST.
dx_runtime_docker_host_dir_marker_set() {
    local nl=$'\n' why="" source="" stream
    if [ "$#" -ne 4 ]; then
        echo "dx: refusing to set the NAS directory's marker: expected ROOT GUEST EXPECTED_STATE MARKER_TEXT" >&2
        return 1
    fi
    case "$1" in
        "" | [!/]* | *,* | *"$nl"*) why="the share root '$1' cannot be bound: it must be an absolute path without ',' or a newline" ;;
    esac
    dx_persist_marker_valid_name "$2" || why="${why:-invalid guest name for the NAS directory: $2}"
    dx_persist_marker_valid_state "$3" || why="${why:-unknown expected marker state '$3'}"
    if dx_persist_marker_parse 2>/dev/null <<<"$4"; then
        [ "$DX_PERSIST_MARKER_GUEST" = "$2" ] || why="${why:-the new marker names guest $DX_PERSIST_MARKER_GUEST, not $2}"
        source="$DX_PERSIST_MARKER_SOURCE_VOLUME"
    else
        why="${why:-the new marker text is not a valid marker}"
    fi
    [ -n "${DX_IMAGE:-}" ] || why="${why:-no DX_IMAGE to run the one-off container from}"
    if [ -n "$why" ]; then
        echo "dx: refusing to set the NAS directory's marker: $why" >&2
        return 1
    fi
    stream="$(dx_runtime_docker_host_dir_marker_stream "$4" && printf x)" || return 1
    stream="${stream%x}"
    printf '%s' "$stream" | dx_runtime_docker_cli run --rm -i --network none --user 0:0 --pull never \
        --mount "type=bind,source=$1,target=$DX_RUNTIME_DOCKER_HOST_DIR_BIND_TARGET" \
        --entrypoint sh "$DX_IMAGE" -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_SET_SCRIPT" sh \
        "$DX_RUNTIME_DOCKER_HOST_DIR_BIND_TARGET" "$2" "$3" "$source" >&2
}

# The migration's verification (WP6.4; plans/do D-8; spec R33): the WP6.1
# manifest tool's text is the inline script of ONE read-only one-off container
# from $DX_IMAGE, whose own bash 5, coreutils and findutils run it (no nix
# volume: the guest's root profile has no findutils). The volume is mounted
# ":ro" after its DQ6 check and the host directory as a readonly bind, so the
# verification cannot change either side. Read at call time, never at import.
DX_RUNTIME_DOCKER_MANIFEST_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/container/dx-nixos-26.05/scripts/lib/dx-persist-manifest.sh"

# dx_runtime_docker_host_manifest_verify forward|reverse VOLUME DIR. The
# checks before any call print a `dx:` reason (status 1); the tool's stdout,
# stderr and status (0 match, 1 differ, 2 error) pass through unchanged.
dx_runtime_docker_host_manifest_verify() {
    local nl=$'\n' direction="${1:-}" volume="${2:-}" dir="${3:-}" mounts=() why="" tool
    [ "$#" -eq 3 ] || why="expected forward|reverse VOLUME DIR"
    case "$direction" in
        forward) mounts=(-v "$volume:/src:ro" --mount "type=bind,source=$dir,target=/dst,readonly") ;;
        reverse) mounts=(--mount "type=bind,source=$dir,target=/src,readonly" -v "$volume:/dst:ro") ;;
        *) why="${why:-unknown direction '$direction' (forward or reverse)}" ;;
    esac
    case "$dir" in
        / | *,* | *"$nl"* | [!/]* | "") why="${why:-the directory '$dir' cannot be bound: it must be an absolute path other than / without ',' or a newline}" ;;
    esac
    [ -n "${DX_IMAGE:-}" ] || why="${why:-no DX_IMAGE to run the one-off container from}"
    if [ -n "$why" ]; then
        echo "dx: refusing to verify the manifest: $why" >&2
        return 1
    fi
    if ! tool="$(cat -- "$DX_RUNTIME_DOCKER_MANIFEST_TOOL" 2>/dev/null)" || [ -z "$tool" ]; then
        echo "Error: cannot read the manifest tool $DX_RUNTIME_DOCKER_MANIFEST_TOOL." >&2
        return 2
    fi
    dx_runtime_docker_volume_owned "$volume" verify || return 1
    dx_runtime_docker_cli run --rm --network none --user 0:0 --pull never "${mounts[@]}" \
        --entrypoint bash "$DX_IMAGE" -c "$tool" dx-persist-manifest verify /src /dst
}
