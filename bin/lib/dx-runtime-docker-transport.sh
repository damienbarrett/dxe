#!/bin/bash
# Docker-over-SSH transport primitives: quoting, the ssh option set, the two
# raw/exec ssh entry points, cached binary-path lookup, and the one
# production `dx_runtime_docker_cli` call site. Split from
# bin/lib/dx-runtime-docker.sh (WP8.3 step 3; findings.md, docs/reviews/
# 2026-09-29-muse.md A2, docs/reviews/2026-09-29-astra.md R3); that file
# remains the facade every caller sources and dispatches through.
#
# Safe to source: defines functions and constants only, no I/O, no command
# dispatch, no shell options, at import time (same contract as every other
# bin/lib/*.sh file).

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
# external data at all (bin-path discovery, in dx-runtime-docker-identity.sh).
# Everything else goes through dx_runtime_docker_ssh_exec. Newline-per-token
# idiom to build the ssh_opts array (Bash 3.2 has no array-returning
# functions), exactly tests/qnap/lib/phase0-common.sh's own
# ssh_opts-building shape.

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

# Returns the cached path, discovering it first if this process (or a
# parent it inherited the export from) has not already done so.
# dx_runtime_docker_discover_bin itself is defined in
# dx-runtime-docker-identity.sh; the facade sources that file too, so it is
# always available by the time any of these functions actually run.
dx_runtime_docker_require_bin() {
    if [ -z "${DXE_RUNTIME_DOCKER_BIN:-}" ]; then
        dx_runtime_docker_discover_bin || return 1
    fi
    printf '%s' "$DXE_RUNTIME_DOCKER_BIN"
}

# The one production entry point for "run the discovered docker CLI, with
# these verb/args, on DX_REMOTE_HOST" (Fable A7; findings.md WP8.3 step 2).
# Every dx_runtime_docker_<op> below whose ENTIRE remote call is "resolve
# the binary, then run one docker verb with it" calls this instead of
# repeating `local bin; bin="$(dx_runtime_docker_require_bin)" || return 1;
# dx_runtime_docker_ssh_exec "$bin" ...` at its own top -- a second
# `dx_runtime_docker_require_bin` call within the same process is a cached,
# no-op read (dx_runtime_docker_discover_bin's own top guard), never a
# second ssh round trip, so a caller that already resolved `bin` itself for
# some OTHER reason (a label lookup, the exec tty branch's own raw ssh
# call) and also calls this loses nothing by doing so. Exit status and
# stdin/stdout/stderr pass through unchanged, exactly like
# dx_runtime_docker_ssh_exec itself (a plain function call, no subshell or
# pipe of its own).

dx_runtime_docker_cli() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" "$@"
}
