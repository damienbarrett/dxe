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

# --- Preflight (item 2) ----------------------------------------------------

# Real (never skippable) reachability check: BatchMode means a dead host,
# bad key, or no tty fails within ConnectTimeout seconds rather than hanging
# or prompting. Distinguishing connection-loss from auth-failure is item 8's
# job (dx_runtime_docker_classify_ssh_failure, added with the rest of the
# diagnostics taxonomy); this function only reports success/failure.
dx_runtime_docker_host_reachable() {
    dx_runtime_docker_ssh_raw true >/dev/null 2>&1
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
    local bin="$1" server_version
    server_version="$(dx_runtime_docker_ssh_exec "$bin" version --format '{{.Server.Version}}' 2>/dev/null)" || return 1
    server_version="$(printf '%s\n' "$server_version" | tail -n1 | tr -d '\r')"
    [ -n "$server_version" ]
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
        echo "Error: cannot reach QNAP host alias '$DX_REMOTE_HOST' over a non-interactive SSH connection (BatchMode=yes, ConnectTimeout=${DX_SSH_CONNECT_TIMEOUT:-15}s). Check the 'Host $DX_REMOTE_HOST' stanza in ~/.ssh/config and that the NAS is reachable over Tailscale." >&2
        return 1
    }
    dx_runtime_docker_check_arch || return 1
    dx_runtime_docker_discover_bin || return 1
    dx_runtime_docker_engine_compatible "$DXE_RUNTIME_DOCKER_BIN" || {
        echo "Error: Docker CLI/Engine on $DX_REMOTE_HOST did not report a compatible server version (docker version --format '{{.Server.Version}}' failed or was empty)." >&2
        return 1
    }
    dx_runtime_docker_discover_daemon_id || return 1
}

# dx_runtime_system_running's docker-ssh implementation: a fast, live
# daemon-reachable check (analogous to Apple's `container system status`),
# reusing an already-discovered binary path but not re-running the full
# preflight chain above.
dx_runtime_docker_system_running() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" info >/dev/null 2>&1
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
