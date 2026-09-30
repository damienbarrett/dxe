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

dx_runtime_docker_container_exists() {
    dx_runtime_docker_cli container inspect "$1" >/dev/null 2>&1
}

dx_runtime_docker_container_running() {
    local state
    state="$(dx_runtime_docker_cli container inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" || return 1
    state="$(printf '%s\n' "$state" | tail -n1 | tr -d '\r')"
    [ "$state" = true ]
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

dx_runtime_docker_container_create() {
    dx_runtime_docker_require_bin >/dev/null || return 1
    local name="" image="" entrypoint_cmd="" flags=() entrypoint_args=() guest_addr=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --image) image="$2"; shift 2 ;;
            --volume)
                dx_runtime_container_create_parse_volume_spec "$2" || return 1
                case "$DXE_VOLSPEC_ROLE" in
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
    dx_runtime_docker_cli create --name "$name" --entrypoint sh \
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
# Docker's own real create flags (above).

dx_runtime_docker_capability() {
    case "$1" in
        direct_named_volume_mounts) return 0 ;;
        bind_mounts) return 1 ;;
        restart_policy) return 0 ;;
        host_filesystem_reclamation) return 1 ;;
        raw_nix_disk) return 1 ;;
        container_healthcheck) return 0 ;;
        *) echo "Error: unknown runtime capability '$1'." >&2; return 2 ;;
    esac
}

