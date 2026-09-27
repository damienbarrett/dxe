#!/bin/bash
# Remote Docker-over-SSH runtime adapter (Branch 11 / Phase 2,
# qnap-dxe-plan.md DQ1-DQ8). Every dx_runtime_docker_<op> function here is
# DX_RUNTIME=docker-ssh's implementation of the matching dx_runtime_<op>
# contract operation (bin/lib/dx-runtime.sh), which dispatches to it exactly
# the way it dispatches to dx_runtime_apple_<op> for DX_RUNTIME=apple. See
# docs/refactor/docker-adapter-mapping.md for the full command-by-command
# design this file implements, and docs/refactor/runtime-boundary.md for the
# contract shape.
#
# DQ1: every remote invocation is a plain, non-interactive SSH command --
# `ssh -o BatchMode=yes ... <DX_REMOTE_HOST> <docker-abs-path> <verb> ...` --
# never Docker's own `-H ssh://` transport (Phase 0 confirmed it fails: the
# NAS's non-interactive PATH lacks `docker`, and Docker's ssh transport just
# runs `docker ...` on whatever that shell resolves). The Docker CLI's
# absolute path is discovered once per process and cached (section "Docker
# binary path discovery" below); nothing here re-derives it per call.
#
# Quoting discipline (see docs/refactor/docker-adapter-mapping.md section 1):
# SSH's exec channel has no real remote argv -- the client joins every
# trailing argument after the destination with one space and hands the
# result to the remote login shell to parse as ONE command line
# (tests/qnap/phase0-spike.sh hit this directly and fixed it the same way
# this file does). So every value that is not a fixed, author-written
# constant crosses through dx_runtime_docker_quote_argv, which %q-quotes
# each token individually before the tokens are joined with plain spaces --
# this is how "positional data, never interpolated executable text" (DQ1)
# is achieved over a transport that only ever accepts one string.
#
# Structured output (item 3): every query uses Docker's own `--format` Go
# templates to extract exactly the scalar field(s) needed (`{{.State.Running}}`,
# `{{index .Config.Labels "io.dxe.role"}}`, ...), never `docker ... | awk`
# table parsing and never a JSON blob that would need a JSON parser on the
# controller (the Mac side has no guaranteed `jq`; unlike the guest, which
# does, per its own flake). A handful of fields needed together are
# requested as one pipe-delimited template (e.g.
# `{{.ID}}|{{.Architecture}}`) so one ssh round trip yields all of them.
#
# Safe to source: defines functions and constants only, no I/O, no command
# dispatch, no shell options, at import time (same contract as
# dx-runtime-apple.sh and every other bin/lib/*.sh file).

# --- Quoting and the single remote command string -------------------------

# %q-quote every token in "$@" and join with plain spaces into one string --
# what ssh's own argument-rejoining requires to preserve each token as a
# single word for the remote shell (see the module comment above). `printf
# %q` has been a bash builtin since well before 3.2, so this is safe on this
# Mac's system bash as well as the guest's.
dx_runtime_docker_quote_argv() {
    local out="" tok first=1
    for tok in "$@"; do
        if [ "$first" -eq 1 ]; then out="$(printf '%q' "$tok")"; first=0
        else out="$out $(printf '%q' "$tok")"
        fi
    done
    printf '%s' "$out"
}

# The management-plane ssh options every call uses: never interactive, never
# a host-key prompt, fails fast on a dead endpoint. Reuses DX_SSH_CONNECT_TIMEOUT
# (the one existing timeout field) rather than adding a new registry field
# for what is, in practice, the same "how long to wait for a dead endpoint"
# concern DQ3 did not call out separately.
dx_runtime_docker_ssh_option_argv() {
    printf '%s\n' \
        -o BatchMode=yes \
        -o ConnectTimeout="${DX_SSH_CONNECT_TIMEOUT:-15}" \
        -o LogLevel=ERROR
}

# Run a single already-complete remote command STRING (never token-quoted
# again here -- the caller decided whether it needed quoting). Used only for
# the one class of remote invocation that is not a flat docker verb/argv: a
# small, fully author-controlled POSIX-sh snippet with no interpolated
# external data at all (bin-path discovery below). Everything else goes
# through dx_runtime_docker_ssh_exec. Newline-per-token idiom to build the
# ssh_opts array (Bash 3.2 has no array-returning functions), exactly
# tests/qnap/lib/phase0-common.sh's own ssh_opts-building shape.
dx_runtime_docker_ssh_raw() {
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dx_runtime_docker_ssh_option_argv)"
    ssh "${ssh_opts[@]}" "${DX_REMOTE_HOST:?}" "$1"
}

# The one production entry point for "run <docker-bin> <verb> <args...> on
# DX_REMOTE_HOST": quotes every argument, joins into ssh's single remote
# command string, and runs it with stdin/stdout/stderr all passed straight
# through (no capture, no intermediate pipe or subshell of its own) so this
# function's exit status is the remote command's, unchanged, exactly like
# dx_runtime_apple_exec's container passthrough. A caller that wants to
# capture output wraps a call to this function in "$(...)" itself; nothing
# about this function's own body changes between the two uses.
dx_runtime_docker_ssh_exec() {
    dx_runtime_docker_ssh_raw "$(dx_runtime_docker_quote_argv "$@")"
}

# --- Docker binary path discovery (item 2; qnap-dxe-plan.md DQ1) ----------
#
# Confirmed by Phase 0 against the real NAS: the non-interactive SSH PATH
# does not include the Container Station qpkg's own bin directory, so a
# bare `command -v docker` over ssh finds nothing -- the absolute path must
# be discovered once and reused. This snippet is POSIX-sh (ash/BusyBox-safe,
# no bashisms) because it runs on the remote host's default non-interactive
# shell, matching tests/qnap/lib/phase0-common.sh's
# dxe_qpkg_binary_discovery_snippet/dxe_qnap_docker_discovery_remote_script
# shape exactly -- same technique, a fresh production copy (that file lives
# under tests/, this one under bin/lib/, so bin/ code cannot source it
# without inverting the test/production dependency direction). It contains
# no interpolated external data (the glob and command name are fixed
# constants this file's own author wrote), so it is sent as ONE fixed
# string via dx_runtime_docker_ssh_raw, not per-token quoted.
DX_RUNTIME_DOCKER_BIN_GLOB='/share/*/.qpkg/container-station/bin/docker'

dx_runtime_docker_bin_discovery_script() {
    printf 'DXE_DOCKER_BIN=""\nif command -v docker >/dev/null 2>&1; then DXE_DOCKER_BIN="$(command -v docker)"; else for dxe_cand in %s; do if [ -x "$dxe_cand" ]; then DXE_DOCKER_BIN="$dxe_cand"; break; fi; done; fi\necho "${DXE_DOCKER_BIN:-NOTFOUND}"\n' \
        "$DX_RUNTIME_DOCKER_BIN_GLOB"
}

# Discovers the Docker CLI's absolute path (one ssh round trip) and caches
# it in DXE_RUNTIME_DOCKER_BIN, exported so a child process this one execs
# or plainly invokes inherits it and never re-discovers it (qnap-dxe-plan.md
# Phase 2's design note: "discovered once per run ... cached in the resolved
# configuration snapshot, never re-read by children"). Idempotent: a second
# call in the same process (or a process that inherited the export) is a
# no-op.
dx_runtime_docker_discover_bin() {
    [ -z "${DXE_RUNTIME_DOCKER_BIN:-}" ] || return 0
    local discovered
    discovered="$(dx_runtime_docker_ssh_raw "$(dx_runtime_docker_bin_discovery_script)")" || {
        echo "Error: could not reach $DX_REMOTE_HOST to discover the Docker CLI (connection failed or refused)." >&2
        return 1
    }
    discovered="$(printf '%s\n' "$discovered" | tail -n1 | tr -d '\r')"
    if [ -z "$discovered" ] || [ "$discovered" = NOTFOUND ]; then
        echo "Error: could not discover the Docker CLI's absolute path on $DX_REMOTE_HOST (checked the non-interactive PATH and the Container Station qpkg's own bin directory)." >&2
        return 1
    fi
    DXE_RUNTIME_DOCKER_BIN="$discovered"
    export DXE_RUNTIME_DOCKER_BIN
}

# Returns the cached path, discovering it first if this process (or a
# parent it inherited the export from) has not already done so.
dx_runtime_docker_require_bin() {
    if [ -z "${DXE_RUNTIME_DOCKER_BIN:-}" ]; then
        dx_runtime_docker_discover_bin || return 1
    fi
    printf '%s' "$DXE_RUNTIME_DOCKER_BIN"
}

# --- Diagnostics (item 8) ---------------------------------------------------
#
# Distinct failure classes, not a single generic "command failed": each
# preflight/query/lifecycle call that fails captures the raw stderr text
# from ssh or the remote docker invocation and classifies it here, so the
# error message an operator sees names WHICH of the five classes applies
# (docs/refactor/docker-adapter-mapping.md section 7) rather than leaving
# them to guess. A class this function does not recognize still gets a
# useful, if generic, label ("remote command failure") -- never silence.
dx_runtime_docker_classify_failure() {
    local text="$1"
    case "$text" in
        *"Permission denied"*|*"Host key verification failed"*|*"Too many authentication failures"*)
            printf 'authentication failure' ;;
        *"Connection refused"*|*"Connection closed"*|*"Connection timed out"*|*"Operation timed out"*|*"No route to host"*|*"Could not resolve hostname"*)
            printf 'connection loss' ;;
        *"Cannot connect to the Docker daemon"*|*"Is the docker daemon running"*)
            printf 'daemon restart or unreachable' ;;
        *"command not found"*|*"docker.sock"*"permission denied"*|*"dial unix"*"permission denied"*)
            printf 'missing Docker access' ;;
        *)
            printf 'remote command failure' ;;
    esac
}

# --- Preflight (item 2) ----------------------------------------------------

# Real (never skippable) reachability check: BatchMode means a dead host,
# bad key, or no tty fails within ConnectTimeout seconds rather than hanging
# or prompting. Captures stderr into DXE_RUNTIME_DOCKER_LAST_FAILURE so a
# caller can classify and report it distinctly (item 8) instead of a bare
# pass/fail.
dx_runtime_docker_host_reachable() {
    local stderr_file rc
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/dxe-docker-ssh-stderr.XXXXXX")" || return 1
    rc=0
    dx_runtime_docker_ssh_raw true >/dev/null 2>"$stderr_file" || rc=$?
    DXE_RUNTIME_DOCKER_LAST_FAILURE="$(cat "$stderr_file")"
    rm -f "$stderr_file"
    return "$rc"
}

# uname -m vs DX_GUEST_SYSTEM (DQ7): refuses a mismatch before any Docker
# call, rather than building or running the wrong architecture's image.
dx_runtime_docker_check_arch() {
    local remote_arch mapped
    remote_arch="$(dx_runtime_docker_ssh_exec uname -m)" || {
        echo "Error: could not run 'uname -m' on $DX_REMOTE_HOST." >&2
        return 1
    }
    remote_arch="$(printf '%s\n' "$remote_arch" | tail -n1 | tr -d '\r')"
    case "$remote_arch" in
        aarch64) mapped=aarch64-linux ;;
        x86_64) mapped=x86_64-linux ;;
        *)
            echo "Error: $DX_REMOTE_HOST reports unsupported architecture '$remote_arch' (qnap-dxe-plan.md DQ7: only aarch64/x86_64 are supported)." >&2
            return 1
            ;;
    esac
    if [ "$mapped" != "${DX_GUEST_SYSTEM:-aarch64-linux}" ]; then
        echo "Error: $DX_REMOTE_HOST's actual architecture ($remote_arch -> $mapped) does not match configured DX_GUEST_SYSTEM=${DX_GUEST_SYSTEM:-aarch64-linux}." >&2
        return 1
    fi
}

# Engine/CLI compatibility (item 2): the CLI can reach a compatible daemon.
# `docker version`'s own exit status already fails on most real
# incompatibilities; requiring a non-empty Server.Version on top of exit 0
# catches an unlikely 0-exit/empty-server edge without needing to parse or
# compare version numbers ourselves.
dx_runtime_docker_engine_compatible() {
    local bin="$1" server_version stderr_file rc
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/dxe-docker-version-stderr.XXXXXX")" || return 1
    rc=0
    server_version="$(dx_runtime_docker_ssh_exec "$bin" version --format '{{.Server.Version}}' 2>"$stderr_file")" || rc=$?
    DXE_RUNTIME_DOCKER_LAST_FAILURE="$(cat "$stderr_file")"
    rm -f "$stderr_file"
    [ "$rc" -eq 0 ] || return "$rc"
    server_version="$(printf '%s\n' "$server_version" | tail -n1 | tr -d '\r')"
    if [ -z "$server_version" ]; then
        DXE_RUNTIME_DOCKER_LAST_FAILURE="docker version --format '{{.Server.Version}}' exited 0 but printed no server version"
        return 1
    fi
}

# Stable remote daemon identity (item 2's "stable Docker daemon ID"; feeds
# item 7's identity scoping). One round trip for both the primary ID and
# the fallback fields, pipe-delimited (never JSON -- no jq on the
# controller). Cached like the binary path: a second call in the same
# process reuses it.
dx_runtime_docker_discover_daemon_id() {
    [ -z "${DXE_RUNTIME_DOCKER_DAEMON_ID:-}" ] || return 0
    local bin fields id name arch os
    bin="$(dx_runtime_docker_require_bin)" || return 1
    fields="$(dx_runtime_docker_ssh_exec "$bin" info --format '{{.ID}}|{{.Name}}|{{.Architecture}}|{{.OperatingSystem}}' 2>/dev/null)" || {
        echo "Error: could not query Docker daemon info on $DX_REMOTE_HOST." >&2
        return 1
    }
    fields="$(printf '%s\n' "$fields" | tail -n1 | tr -d '\r')"
    IFS='|' read -r id name arch os <<<"$fields"
    if [ -n "$id" ]; then
        DXE_RUNTIME_DOCKER_DAEMON_ID="$id"
    else
        DXE_RUNTIME_DOCKER_DAEMON_ID="$(dx_short_hash "$name|$arch|$os")"
    fi
    export DXE_RUNTIME_DOCKER_DAEMON_ID
}

# dx_runtime_available's docker-ssh implementation: the complete read-only
# preflight chain (host reachability, docker path discovery, architecture
# check, engine/CLI compatibility, daemon identity), run in full every call
# -- only the binary path and daemon ID are cached across calls within the
# same process; reachability and compatibility are live checks every time,
# since a daemon or connection can change state between calls.
dx_runtime_docker_available() {
    dx_runtime_docker_host_reachable || {
        local class
        class="$(dx_runtime_docker_classify_failure "${DXE_RUNTIME_DOCKER_LAST_FAILURE:-}")"
        echo "Error: cannot reach QNAP host alias '$DX_REMOTE_HOST' over a non-interactive SSH connection ($class; BatchMode=yes, ConnectTimeout=${DX_SSH_CONNECT_TIMEOUT:-15}s). Check the 'Host $DX_REMOTE_HOST' stanza in ~/.ssh/config and that the NAS is reachable over Tailscale.${DXE_RUNTIME_DOCKER_LAST_FAILURE:+ (ssh said: $DXE_RUNTIME_DOCKER_LAST_FAILURE)}" >&2
        return 1
    }
    dx_runtime_docker_check_arch || return 1
    dx_runtime_docker_discover_bin || return 1
    dx_runtime_docker_engine_compatible "$DXE_RUNTIME_DOCKER_BIN" || {
        local class
        class="$(dx_runtime_docker_classify_failure "${DXE_RUNTIME_DOCKER_LAST_FAILURE:-}")"
        echo "Error: Docker CLI/Engine on $DX_REMOTE_HOST is not usable ($class): docker version --format '{{.Server.Version}}' failed or printed no server version.${DXE_RUNTIME_DOCKER_LAST_FAILURE:+ (docker said: $DXE_RUNTIME_DOCKER_LAST_FAILURE)}" >&2
        return 1
    }
    dx_runtime_docker_discover_daemon_id || return 1
}

# dx_runtime_system_running's docker-ssh implementation: a fast, live
# daemon-reachable check (analogous to Apple's `container system status`),
# reusing an already-discovered binary path but not re-running the full
# preflight chain above.
dx_runtime_docker_system_running() {
    local bin stderr_file rc
    bin="$(dx_runtime_docker_require_bin)" || return 1
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/dxe-docker-info-stderr.XXXXXX")" || return 1
    rc=0
    dx_runtime_docker_ssh_exec "$bin" info >/dev/null 2>"$stderr_file" || rc=$?
    DXE_RUNTIME_DOCKER_LAST_FAILURE="$(cat "$stderr_file")"
    rm -f "$stderr_file"
    return "$rc"
}

# dx_runtime_system_start's docker-ssh implementation: always refuses.
# Starting or restarting Container Station's Docker Engine is a
# service-restart-class action on production infrastructure (the standing
# "no service restart without explicit per-instance approval" rule); this
# adapter never issues one. The operator restarts it from the NAS's own
# QTS/QuTS App Center UI.
dx_runtime_docker_system_start() {
    echo "Error: the docker-ssh runtime never starts or restarts Container Station's Docker Engine remotely. If it is not running, start it from the NAS's own App Center UI (Container Station)." >&2
    return 1
}

# dx_runtime_host_identity's docker-ssh implementation (item 2 feeds item 7):
# "docker-ssh:<alias>:<daemon-id>" -- the alias distinguishes two profiles
# pointed at different NASs even before any daemon call succeeds; the daemon
# ID additionally catches an alias that silently starts resolving to a
# different daemon underneath an unchanged name.
dx_runtime_docker_host_identity() {
    dx_runtime_docker_discover_daemon_id || return 1
    printf 'docker-ssh:%s:%s\n' "$DX_REMOTE_HOST" "$DXE_RUNTIME_DOCKER_DAEMON_ID"
}

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
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" image inspect "$1" >/dev/null 2>&1
}

# Branch 11 / Phase 3 (docs/refactor/direct-volume-storage.md section 5.1):
# the runtime's own stable image identity, forwarded by
# bin/dx-create-container as DX_IMAGE_IDENTITY so the direct-volume guest
# can detect an image bump on a reused volume without reaching the image's
# own (hidden-under-the-mount) store. Structured, single-field query, the
# same shape tests/qnap/phase0-spike.sh already uses for its own base/tag
# digest comparison; Docker's template renders "sha256:<hex>" itself, no
# parsing needed on the controller.
dx_runtime_docker_image_identity() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" image inspect --format '{{.Id}}' "$1"
}

dx_runtime_docker_image_list() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" image ls "$@" --format 'table {{.Repository}}:{{.Tag}}	{{.ID}}	{{.CreatedSince}}	{{.Size}}'
}

dx_runtime_docker_volume_exists() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" volume inspect "$1" >/dev/null 2>&1
}

dx_runtime_docker_container_exists() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" container inspect "$1" >/dev/null 2>&1
}

dx_runtime_docker_container_running() {
    local bin state
    bin="$(dx_runtime_docker_require_bin)" || return 1
    state="$(dx_runtime_docker_ssh_exec "$bin" container inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" || return 1
    state="$(printf '%s\n' "$state" | tail -n1 | tr -d '\r')"
    [ "$state" = true ]
}

dx_runtime_docker_container_list() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" ps "$@" --format 'table {{.Names}}	{{.Image}}	{{.Status}}'
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
# The shared --publish "127.0.0.1:PORT:2222" spec is forwarded as-is
# (loopback, unreachable from a real remote NAS) -- making the guest SSH
# publish address remote-aware is qnap-dxe-plan.md Phase 5's job ("Make
# SSH and user workflows remote-aware"), not Phase 2's.

# --- DQ6 labels -------------------------------------------------------
#
# Schema version for the label set itself (bumped only if the label KEYS
# or their meaning change, independent of DXE_CONFIG_SNAPSHOT_VERSION_CURRENT
# which versions the unrelated configuration-snapshot shape).
DXE_RUNTIME_DOCKER_LABEL_SCHEMA=1

# A profile identifies "this docker-ssh profile" for collision detection
# (qnap-dxe-plan.md DQ6's io.dxe.profile) -- computable from plain resolved
# config fields, no remote call needed. Distinct from
# dx_runtime_docker_host_identity's daemon-ID-based identity (item 7's
# concern: telling two DIFFERENT remote daemons apart even if their alias
# were reused); this is "which DXE profile," not "which physical NAS."
dx_runtime_docker_profile_id() {
    printf '%s__%s' "${DX_REMOTE_HOST:?}" "${DX_CONTAINER_NAME:?}"
}

# Populates DXE_RUNTIME_DOCKER_LABEL_ARGV with the four `--label k=v` pairs
# every docker-ssh-created resource carries (qnap-dxe-plan.md DQ6). One
# line, not kcov's usual multi-line array-literal style: kcov's line-based
# instrumentation does not reliably attribute a hit to every continuation
# line of a multi-line array assignment (confirmed: the 4 continuation
# lines of an earlier draft never registered a hit despite this function
# running constantly), the same class of kcov limitation
# tests/run-coverage-linux.sh's own KCOV_SUBSHELL_TERMINATOR works around.
dx_runtime_docker_label_flags() {
    DXE_RUNTIME_DOCKER_LABEL_ARGV=(--label io.dxe.managed=true --label "io.dxe.schema=$DXE_RUNTIME_DOCKER_LABEL_SCHEMA" --label "io.dxe.profile=$(dx_runtime_docker_profile_id)" --label "io.dxe.role=$1")
}

dx_runtime_docker_container_create() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    local name="" image="" entrypoint_cmd="" flags=() entrypoint_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --image) image="$2"; shift 2 ;;
            --volume)
                dx_runtime_container_create_parse_volume_spec "$2" || return 1
                case "$DXE_VOLSPEC_ROLE" in
                    nix) flags+=(--volume "$DXE_VOLSPEC_NAME:/nix:$DXE_VOLSPEC_MODE") ;;
                    *) flags+=(--volume "$DXE_VOLSPEC_NAME:$DXE_VOLSPEC_TARGET:$DXE_VOLSPEC_MODE") ;;
                esac
                shift 2
                ;;
            --env) flags+=(-e "$2"); shift 2 ;;
            --memory) flags+=(-m "$2"); shift 2 ;;
            --cpus) flags+=(--cpus "$2"); shift 2 ;;
            --publish) flags+=(-p "$2"); shift 2 ;;
            --restart-policy) flags+=(--restart "$2"); shift 2 ;;
            --entrypoint-cmd) entrypoint_cmd="$2"; shift 2 ;;
            --entrypoint-arg) entrypoint_args+=("$2"); shift 2 ;;
            *) echo "Error: dx_runtime_docker_container_create: unknown parameter '$1'." >&2; return 1 ;;
        esac
    done
    [ -n "$name" ] || { echo "Error: dx_runtime_docker_container_create: --name is required." >&2; return 1; }
    [ -n "$image" ] || { echo "Error: dx_runtime_docker_container_create: --image is required." >&2; return 1; }
    dx_runtime_docker_label_flags container
    dx_runtime_docker_ssh_exec "$bin" create --name "$name" --entrypoint sh \
        "${flags[@]}" "${DXE_RUNTIME_DOCKER_LABEL_ARGV[@]}" \
        "$image" -c "$entrypoint_cmd" -- "${entrypoint_args[@]}"
}

dx_runtime_docker_container_start() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" start "$@"
}

dx_runtime_docker_container_stop() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" stop "$@"
}

dx_runtime_docker_container_kill() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" kill "$@"
}

# --- DQ6 label verification before deletion (item 5) -----------------------
#
# "An existing same-named unlabelled or differently labelled object is a
# collision, not an adoption candidate" (DQ6). Checked here, not at create
# time: dx_runtime_volume_create/dx_runtime_container_create are only ever
# reached after an existing caller's own dx_runtime_*_exists check already
# returned false (bin/lib/dx-container.sh's container_ensure_volume:
# "dx_runtime_volume_exists ... || dx_runtime_volume_create ..."), so a
# collision at CREATE time is a create-then-immediately-delete question the
# existing entrypoints do not raise; DESTRUCTIVE commands always run
# unconditionally against a name the caller already resolved to exist, so
# this is where "prove ownership before mutation" actually bites, matching
# the plan's own item-5 wording: "Add DQ6 labels and collision refusal
# before enabling deletion."
#
# Images are the one exception: qnap-dxe-plan.md Phase 0 found the NAS
# refuses a remote `docker build`, so image_build (above) never builds --
# it pulls and tags a pinned reference, and `docker tag` cannot attach a
# label (only a build or commit can). There is therefore no label DQ6
# could check for an image; image_delete's only available protection is
# the exact-name addressing its one caller (bin/dx-destroy-image) already
# provides. Documented here rather than silently pretended away.

dx_runtime_docker_volume_labels() {
    local bin="$1" name="$2" fields
    fields="$(dx_runtime_docker_ssh_exec "$bin" volume inspect --format '{{index .Labels "io.dxe.managed"}}|{{index .Labels "io.dxe.schema"}}|{{index .Labels "io.dxe.profile"}}|{{index .Labels "io.dxe.role"}}' "$name" 2>/dev/null)" || return 1
    printf '%s\n' "$fields" | tail -n1 | tr -d '\r'
}

dx_runtime_docker_container_labels() {
    local bin="$1" name="$2" fields
    fields="$(dx_runtime_docker_ssh_exec "$bin" container inspect --format '{{index .Config.Labels "io.dxe.managed"}}|{{index .Config.Labels "io.dxe.schema"}}|{{index .Config.Labels "io.dxe.profile"}}|{{index .Config.Labels "io.dxe.role"}}' "$name" 2>/dev/null)" || return 1
    printf '%s\n' "$fields" | tail -n1 | tr -d '\r'
}

# Shared refusal logic: given a "managed|schema|profile|role" fields
# string (or a failed lookup) and the expected role, refuse unless every
# field matches this profile exactly.
dx_runtime_docker_verify_labels() {
    local kind="$1" name="$2" expected_role="$3" fields="$4" managed schema profile role
    if [ -z "$fields" ]; then
        echo "Error: refusing to delete $kind '$name': it does not exist or its labels could not be read." >&2
        return 1
    fi
    IFS='|' read -r managed schema profile role <<<"$fields"
    if [ "$managed" != true ] || [ "$profile" != "$(dx_runtime_docker_profile_id)" ] || [ "$role" != "$expected_role" ]; then
        echo "Error: refusing to delete $kind '$name': it exists but is unlabelled or labelled for a different profile/role (qnap-dxe-plan.md DQ6 -- this is a collision, not an adoption candidate). Found managed=${managed:-<none>} schema=${schema:-<none>} profile=${profile:-<none>} role=${role:-<none>}; expected managed=true profile=$(dx_runtime_docker_profile_id) role=$expected_role." >&2
        return 1
    fi
}

# Apple's verb is "delete"; Docker's is "rm" -- otherwise identical flags
# (Apple --force, Docker -f/--force). The container name is always the
# last argument (bin/dx-destroy-container calls this as either
# "dx_runtime_container_delete NAME" or
# "dx_runtime_container_delete --force NAME").
dx_runtime_docker_container_delete() {
    local bin name fields
    bin="$(dx_runtime_docker_require_bin)" || return 1
    for name in "$@"; do :; done
    fields="$(dx_runtime_docker_container_labels "$bin" "$name")" || true
    dx_runtime_docker_verify_labels container "$name" container "$fields" || return 1
    dx_runtime_docker_ssh_exec "$bin" rm "$@"
}

# The Containerfile's pinned base image reference. qnap-dxe-plan.md's
# Phase 0 outcome: the real NAS refuses `docker build` outright for its
# account ("QNAP's Docker wrapper creates a per-user build directory ...
# and refuses it there for a non-default administrator"). Confirmed by the
# coordinating session (2026-09-27): the Containerfile in this repository
# is, and is meant to stay, a single "FROM <pinned-ref>@sha256:..." line --
# the guest's actual content comes from the bootstrap volume, not image
# layers -- so docker-ssh's "build" is exactly Phase 0's spike's proven
# steps 2+3: pull the pinned reference, then tag it as the configured
# image name. No remote build, no local build + save/load: never touches a
# remote build context directory at all. Fails closed with a clear message
# if the Containerfile ever contains anything beyond that one FROM line
# (a second stage, a RUN/COPY instruction, ...) rather than silently
# building only part of it or ignoring the rest.
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
    local image="" context_dir="" bin ref
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
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" pull "$ref" || return 1
    dx_runtime_docker_ssh_exec "$bin" tag "$ref" "$image"
}

# No label check possible (see this section's own module comment): images
# are never labelled under the pull+tag-only build design. The one caller
# (bin/dx-destroy-image) already addresses by exact configured name; that
# is the only protection available here.
dx_runtime_docker_image_delete() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" image rm "$@"
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
    local bin role
    bin="$(dx_runtime_docker_require_bin)" || return 1
    role="$(dx_runtime_docker_volume_role "$1")" || {
        echo "Error: dx_runtime_docker_volume_create: '$1' is not one of the configured DXE volumes (DX_NIX_VOLUME/DX_PERSIST_VOLUME/DX_BOOTSTRAP_VOLUME); refusing to create it unlabelled (qnap-dxe-plan.md DQ6)." >&2
        return 1
    }
    dx_runtime_docker_label_flags "$role"
    dx_runtime_docker_ssh_exec "$bin" volume create "${DXE_RUNTIME_DOCKER_LABEL_ARGV[@]}" "$@"
}

dx_runtime_docker_volume_delete() {
    local bin name role fields
    bin="$(dx_runtime_docker_require_bin)" || return 1
    for name in "$@"; do :; done
    role="$(dx_runtime_docker_volume_role "$name")" || {
        echo "Error: refusing to delete volume '$name': not one of the configured DXE volumes (DX_NIX_VOLUME/DX_PERSIST_VOLUME/DX_BOOTSTRAP_VOLUME)." >&2
        return 1
    }
    fields="$(dx_runtime_docker_volume_labels "$bin" "$name")" || true
    dx_runtime_docker_verify_labels volume "$name" "$role" "$fields" || return 1
    dx_runtime_docker_ssh_exec "$bin" volume rm "$@"
}

# Branch 11 / Phase 3 (qnap-dxe-plan.md Phase 3 item 5): a capability-aware
# size report for bin/dx-reclaim. Docker has no host-side sparse image to
# measure (DQ4); `docker system df -v` is the structured, Docker-native
# usage query. Rather than requesting the whole `--format '{{json .}}'`
# blob and parsing it on the controller (no guaranteed jq -- this file's
# own module comment), the volume name is validated (it can only ever be
# one of the configured DXE volumes, already constrained to
# [A-Za-z0-9_.-] by bin/lib/dx-config.sh's own validation, so it is safe to
# interpolate into a Go template string) and Docker's own template engine
# does the filtering server-side, returning just the one matching volume's
# byte size as a plain scalar -- no JSON parsing needed on either side.
# "unknown" covers every way Docker cannot say: the query fails outright,
# or the volume is absent from the report, or the returned text is not a
# plain byte count.
dx_runtime_docker_volume_usage() {
    local bin name output
    bin="$(dx_runtime_docker_require_bin)" || return 1
    name="$1"
    output="$(dx_runtime_docker_ssh_exec "$bin" system df -v --format "{{range .Volumes}}{{if eq .Name \"$name\"}}{{.UsageData.Size}}{{end}}{{end}}" 2>/dev/null)" || {
        printf 'unknown\n'
        return 0
    }
    output="$(printf '%s\n' "$output" | tail -n1 | tr -d '\r')"
    case "$output" in
        ''|*[!0-9]*) printf 'unknown\n' ;;
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
dx_runtime_docker_exec() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" exec "$@"
}

dx_runtime_docker_logs() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" logs "$@"
}

dx_runtime_docker_export() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" export "$@"
}

# Ephemeral, no-persistent-container run. Apple's own retry loop
# (dx_runtime_apple_run_ephemeral) exists solely for Apple Container's own
# "no runtime client exists: container is stopped" race
# (docs/refactor/runtime-boundary.md); Docker over SSH has no documented
# equivalent, so no retry is carried over here -- if Increment 8's live
# gate or later characterisation work surfaces a distinct Docker-side race,
# that is new evidence for a scoped retry then, not something to guess at
# now (docs/refactor/docker-adapter-mapping.md section 5).
dx_runtime_docker_run_ephemeral() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" run "$@"
}

# --- Remote per-profile lock (item 6) --------------------------------------
#
# Not part of the Phase 1 dx_runtime_<op> contract (Apple's runtime is
# always local -- one controller, one daemon, no concurrent-invocation
# problem to solve -- so it has no lock concept to dispatch to); called
# directly by bin/dx-lock, the new entrypoint the coordinating session
# authorised for this. Docker's one atomic "create, fail if already
# present" primitive is container-NAME uniqueness (`docker volume create`
# is idempotent and does NOT fail if the volume already exists, so it
# cannot serve as an exclusion primitive; `docker create --name X` fails
# atomically with a "Conflict... name is already in use" error if X
# exists) -- so the lock itself is a labelled, never-started container
# named "dxe-lock-<profile-id>", using the already-pulled/tagged $DX_IMAGE
# as its (never run) base image. The owner label identifies more than a
# PID alone (docs/refactor/constraints.md: "Locks and execution leases
# identify an owner by more than PID alone"): controller hostname, this
# process's PID, a random component, and a UTC timestamp.

dx_runtime_docker_lock_name() {
    printf 'dxe-lock-%s' "$(dx_runtime_docker_profile_id)"
}

dx_runtime_docker_lock_owner_token() {
    local host
    host="$(hostname 2>/dev/null)"
    [ -n "$host" ] || host=unknown-host
    printf '%s:%s:%s:%s' "$host" "$$" "$RANDOM" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# Acquires the lock (create-if-absent, fail-if-held) and prints the owner
# token it just claimed, so a caller that wants to release only its own
# acquisition can pass that exact token back to dx_runtime_docker_lock_release.
dx_runtime_docker_lock_acquire() {
    local bin lock_name owner
    bin="$(dx_runtime_docker_require_bin)" || return 1
    lock_name="$(dx_runtime_docker_lock_name)"
    owner="$(dx_runtime_docker_lock_owner_token)"
    dx_runtime_docker_ssh_exec "$bin" create --name "$lock_name" \
        --label io.dxe.managed=true \
        --label "io.dxe.schema=$DXE_RUNTIME_DOCKER_LABEL_SCHEMA" \
        --label "io.dxe.profile=$(dx_runtime_docker_profile_id)" \
        --label io.dxe.role=lock \
        --label "io.dxe.owner=$owner" \
        "$DX_IMAGE" >/dev/null 2>&1 || {
        echo "Error: could not acquire the remote lock '$lock_name' (it may already be held -- run 'dx-lock status' to see by whom)." >&2
        return 1
    }
    printf '%s' "$owner"
}

# Prints "held by <owner> since <created>" or "not held" -- always
# succeeds (a missing lock is a normal, reportable state, not an error).
# This is the read-only half bin/dx-status exposes.
dx_runtime_docker_lock_audit() {
    local bin lock_name fields owner created
    bin="$(dx_runtime_docker_require_bin)" || return 1
    lock_name="$(dx_runtime_docker_lock_name)"
    fields="$(dx_runtime_docker_ssh_exec "$bin" container inspect --format '{{index .Config.Labels "io.dxe.owner"}}|{{.Created}}' "$lock_name" 2>/dev/null)" || {
        printf 'not held\n'
        return 0
    }
    fields="$(printf '%s\n' "$fields" | tail -n1 | tr -d '\r')"
    IFS='|' read -r owner created <<<"$fields"
    printf 'held by %s since %s\n' "${owner:-<unknown>}" "${created:-<unknown>}"
}

# Explicit unlock (bin/dx-lock's "unlock --force"). Verifies profile/role
# labels first (DQ6: a collision refuses, never an adoption); when
# expected_owner is non-empty, ALSO refuses unless the current owner label
# matches exactly (a caller that acquired the lock itself, releasing only
# its own acquisition). Elapsed time alone is never checked here or
# anywhere in this file -- the audit above is the only way to decide
# staleness, and that decision is the operator's, made outside this
# function, before calling it with --force.
dx_runtime_docker_lock_release() {
    local expected_owner="$1" bin lock_name fields managed profile role owner
    bin="$(dx_runtime_docker_require_bin)" || return 1
    lock_name="$(dx_runtime_docker_lock_name)"
    fields="$(dx_runtime_docker_ssh_exec "$bin" container inspect --format '{{index .Config.Labels "io.dxe.managed"}}|{{index .Config.Labels "io.dxe.profile"}}|{{index .Config.Labels "io.dxe.role"}}|{{index .Config.Labels "io.dxe.owner"}}' "$lock_name" 2>/dev/null)" || {
        echo "Error: no lock '$lock_name' to release." >&2
        return 1
    }
    fields="$(printf '%s\n' "$fields" | tail -n1 | tr -d '\r')"
    IFS='|' read -r managed profile role owner <<<"$fields"
    if [ "$managed" != true ] || [ "$profile" != "$(dx_runtime_docker_profile_id)" ] || [ "$role" != lock ]; then
        echo "Error: refusing to release '$lock_name': it exists but is not labelled as this profile's lock (qnap-dxe-plan.md DQ6 -- a collision, not an adoption candidate)." >&2
        return 1
    fi
    if [ -n "$expected_owner" ] && [ "$owner" != "$expected_owner" ]; then
        echo "Error: refusing to release '$lock_name': it is held by a different owner ($owner), not the one requesting release ($expected_owner)." >&2
        return 1
    fi
    dx_runtime_docker_ssh_exec "$bin" rm "$lock_name" >/dev/null
}

# --- Runtime capability queries (qnap-dxe-plan.md DQ2/DQ3/DQ4/DQ8) --------
#
# See docs/refactor/docker-adapter-mapping.md's capability table for why
# each answer is what it is.
dx_runtime_docker_capability() {
    case "$1" in
        direct_named_volume_mounts) return 0 ;;
        bind_mounts) return 1 ;;
        restart_policy) return 0 ;;
        host_filesystem_reclamation) return 1 ;;
        *) echo "Error: unknown runtime capability '$1'." >&2; return 2 ;;
    esac
}
