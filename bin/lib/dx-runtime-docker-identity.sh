#!/bin/bash
# Docker-over-SSH identity: binary-path and guest-Tailscale-address
# discovery, failure classification, the read-only preflight chain, the
# cross-process daemon-identity cache, dx_runtime_host_identity, the
# collision-detection profile id, and the DQ6 label-verification/ownership
# checks the lifecycle file's mutations call before they delete anything.
# Split from, and one of the four files bin/lib/dx-runtime-docker.sh
# sources (see docs/refactor/decisions/D8-docker-adapter-history.md for
# the split's history); that file remains the facade every caller sources
# and dispatches through, and sources bin/lib/dx-runtime-docker-transport.sh
# before this file, so dx_runtime_docker_ssh_raw/ssh_exec/cli are already
# defined by the time any function below actually runs.
#
# Safe to source: defines functions and constants only, no I/O, no command
# dispatch, no shell options, at import time (same contract as every other
# bin/lib/*.sh file).

# --- Docker binary path discovery (item 2; qnap-dxe-plan.md DQ1) ----------
#
# The non-interactive SSH PATH does not include the Container Station
# qpkg's own bin directory, so a bare `command -v docker` over ssh finds
# nothing -- the absolute path must be discovered once and reused. POSIX-sh
# (ash/BusyBox-safe, no bashisms): it runs on the remote host's default
# non-interactive shell. A fresh production copy of
# tests/qnap/lib/phase0-common.sh's own discovery shape, not a `source` of
# it (that file lives under tests/, this one under bin/lib/, so bin/ code
# cannot source it without inverting the test/production dependency
# direction). No interpolated external data (the glob and command name are
# fixed constants), so it is sent as ONE fixed string via
# dx_runtime_docker_ssh_raw, not per-token quoted.
DX_RUNTIME_DOCKER_BIN_GLOB='/share/*/.qpkg/container-station/bin/docker'

dx_runtime_docker_bin_discovery_script() {
    printf 'DXE_DOCKER_BIN=""\nif command -v docker >/dev/null 2>&1; then DXE_DOCKER_BIN="$(command -v docker)"; else for dxe_cand in %s; do if [ -x "$dxe_cand" ]; then DXE_DOCKER_BIN="$dxe_cand"; break; fi; done; fi\necho "${DXE_DOCKER_BIN:-NOTFOUND}"\n' \
        "$DX_RUNTIME_DOCKER_BIN_GLOB"
}

# Discovers the Docker CLI's absolute path (one ssh round trip) and caches
# it in DXE_RUNTIME_DOCKER_BIN, exported so a child process this one execs
# or plainly invokes inherits it and never re-discovers it. Idempotent: a
# second call in the same process (or a process that inherited the
# export) is a no-op.

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

# --- Guest SSH address discovery (DQ5) -----------------
#
# The address the guest's own SSH server publishes on AND is reached at:
# the NAS's Tailscale IPv4 address, discovered over the existing management
# connection, never loopback/LAN/0.0.0.0, never persisted to any tracked
# file. Reuses tests/qnap/lib/phase0-common.sh's proven discovery shape
# (the Tailscale qpkg CLI's own "ip -4" first, falling back to reading the
# "tailscale0" interface directly) as a fresh production copy, not a
# `source` of that file -- same reason as the bin-discovery snippet above
# (test/production dependency direction). tests/test_docker_runtime_adapter.sh's
# own drift guard sources both files and asserts this function renders
# byte-identical output to tests/qnap/lib/phase0-common.sh's own function
# for the same glob input, so a future edit to either shape cannot silently
# diverge from the other unnoticed.
DX_RUNTIME_DOCKER_TAILSCALE_BIN_GLOB='/share/*/.qpkg/Tailscale/tailscale /share/*/.qpkg/Tailscale/bin/tailscale'

dx_runtime_docker_guest_ssh_address_discovery_script() {
    printf 'DXE_TAILSCALE_BIN=""\nif command -v tailscale >/dev/null 2>&1; then DXE_TAILSCALE_BIN="$(command -v tailscale)"; else for dxe_cand in %s; do if [ -x "$dxe_cand" ]; then DXE_TAILSCALE_BIN="$dxe_cand"; break; fi; done; fi\n' \
        "$DX_RUNTIME_DOCKER_TAILSCALE_BIN_GLOB"
    cat <<'REMOTE'
DXE_TAILNET_ADDR=""
if [ -n "$DXE_TAILSCALE_BIN" ]; then
    DXE_TAILNET_ADDR="$("$DXE_TAILSCALE_BIN" ip -4 2>/dev/null | head -n1)"
fi
if [ -z "$DXE_TAILNET_ADDR" ]; then
    DXE_TAILNET_ADDR="$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
fi
echo "${DXE_TAILNET_ADDR:-NOTFOUND}"
REMOTE
}

# Reused, not duplicated, from tests/test_section1_secrets.sh's own
# pattern for the CGNAT /10 block Tailscale assigns addresses from --
# that file's own leak-scan regex is unanchored (it scans free text for an
# occurrence anywhere this repository must never contain); this validator
# anchors the SAME pattern to require the WHOLE discovered value to match
# it, nothing more or less. (Spelled out here as a range description, not
# a literal dotted-quad example, so this comment cannot itself match the
# very pattern it is describing.)
# tests/test_docker_runtime_adapter.sh's drift guard extracts that file's
# own pattern text and asserts it is identical to this one.
DX_RUNTIME_DOCKER_TAILNET_ADDR_PATTERN='100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'

dx_runtime_docker_guest_ssh_address_valid() {
    printf '%s' "$1" | grep -Eq "^(${DX_RUNTIME_DOCKER_TAILNET_ADDR_PATTERN})\$"
}

# Discovers the NAS's Tailscale address (one ssh round trip) and caches it
# in DXE_RUNTIME_GUEST_SSH_ADDRESS, exported like DXE_RUNTIME_DOCKER_BIN so a
# child process inherits it and never re-discovers it. Idempotent. Never
# loopback/LAN/0.0.0.0 (DQ5): an empty, NOTFOUND, or out-of-range answer
# refuses rather than publishing/dialling somewhere DQ5 forbids.

dx_runtime_docker_discover_guest_ssh_address() {
    [ -z "${DXE_RUNTIME_GUEST_SSH_ADDRESS:-}" ] || return 0
    local discovered
    discovered="$(dx_runtime_docker_ssh_raw "$(dx_runtime_docker_guest_ssh_address_discovery_script)")" || {
        echo "Error: could not reach $DX_REMOTE_HOST to discover its Tailscale address (connection failed or refused)." >&2
        return 1
    }
    discovered="$(printf '%s\n' "$discovered" | tail -n1 | tr -d '\r')"
    if [ -z "$discovered" ] || [ "$discovered" = NOTFOUND ] || ! dx_runtime_docker_guest_ssh_address_valid "$discovered"; then
        echo "Error: the NAS has no Tailscale address; DQ5 forbids publishing on the LAN or 0.0.0.0." >&2
        return 1
    fi
    DXE_RUNTIME_GUEST_SSH_ADDRESS="$discovered"
    export DXE_RUNTIME_GUEST_SSH_ADDRESS
}

# dx_runtime_guest_ssh_address's docker-ssh implementation.

dx_runtime_docker_guest_ssh_address() {
    dx_runtime_docker_discover_guest_ssh_address || return 1
    printf '%s' "$DXE_RUNTIME_GUEST_SSH_ADDRESS"
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

# --- Cross-process daemon-identity cache ---------------
#
# dx_tunnel_key/dx_backup_resolve_dir/dx_ssh_known_hosts_dir (via
# dx_profile_state_segment -> dx_runtime_host_identity, bin/lib/dx-host-util.sh)
# derive every local tunnel socket/metadata/lock path, backup mirror
# directory, and known-hosts pin directory from this identity. Resolving it
# always cost an ssh round trip unless it happened to already be cached IN
# THIS PROCESS, so a later process on an unreachable host -- exactly the
# moment an operator wants `dx-forward --list`/`--stop` to work -- had to
# dial out just to recompute a path for state that already exists locally
# (D8 records the bug this cache fixed). Persisting the resolved daemon id
# once it is known -- 0600, atomic tmp+mv, directory 0700 -- lets a later
# call, in a DIFFERENT process, resolve the SAME identity, and therefore
# the SAME local paths, without ever touching the network again. Scoped by
# DX_CONTAINER_NAME only (like dx_backup_resolve_dir/dx_ssh_known_hosts_dir's
# own existing per-profile segment): a container name is expected to name
# one profile, so repointing the same container name at a different
# DX_REMOTE_HOST is the one case this cache does not freshen until
# something else clears it (an accepted limitation, the same shape as
# dx_backup_resolve_dir's own documented override-argument one).
dx_runtime_docker_daemon_id_cache_path() {
    printf '%s/dxe/%s/host-identity\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "${DX_CONTAINER_NAME:?}"
}

dx_runtime_docker_daemon_id_cache_write() {
    local id="$1" path dir tmp
    path="$(dx_runtime_docker_daemon_id_cache_path)" || return 1
    dir="${path%/*}"
    [ ! -L "$dir" ] || return 1
    mkdir -p "$dir" 2>/dev/null || [ -d "$dir" ] || return 1
    [ ! -L "$dir" ] && [ -d "$dir" ] || return 1
    chmod 0700 "$dir" || return 1
    tmp="$(mktemp "$dir/.host-identity.XXXXXX")" || return 1
    if ! printf '%s\n' "$id" > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
}

dx_runtime_docker_daemon_id_cache_read() {
    local path value
    path="$(dx_runtime_docker_daemon_id_cache_path)" || return 1
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    value="$(sed -n '1p' "$path" 2>/dev/null)"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# Stable remote daemon identity (item 2's "stable Docker daemon ID"; feeds
# item 7's identity scoping). One round trip for both the primary ID and
# the fallback fields, pipe-delimited (never JSON -- no jq on the
# controller). Cached like the binary path: a second call in the same
# process reuses it. Always a LIVE round trip when it actually dials (never
# reads the on-disk cache above itself: dx_runtime_docker_available's own
# full preflight chain calls this directly, precisely because it must prove
# the daemon answers NOW, not "answered at some point in the past" -- see
# that function's own module comment). Only dx_runtime_docker_host_identity,
# below, reads the cache, and only to avoid dialling at all.

dx_runtime_docker_discover_daemon_id() {
    [ -z "${DXE_RUNTIME_DOCKER_DAEMON_ID:-}" ] || return 0
    local fields id name arch os
    fields="$(dx_runtime_docker_cli info --format '{{.ID}}|{{.Name}}|{{.Architecture}}|{{.OperatingSystem}}' 2>/dev/null)" || {
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
    # Best-effort: a cache-write failure (read-only state dir, disk full)
    # must never fail a discovery that already succeeded -- the in-process
    # value above is still correct for the rest of THIS run either way.
    dx_runtime_docker_daemon_id_cache_write "$DXE_RUNTIME_DOCKER_DAEMON_ID" || true
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
    local stderr_file rc
    dx_runtime_docker_require_bin >/dev/null || return 1
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/dxe-docker-info-stderr.XXXXXX")" || return 1
    rc=0
    dx_runtime_docker_cli info >/dev/null 2>"$stderr_file" || rc=$?
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
#
# Reads the on-disk daemon-id cache BEFORE ever dialling, seeding
# DXE_RUNTIME_DOCKER_DAEMON_ID from it when this process has not resolved
# one yet -- dx_runtime_docker_discover_daemon_id's own top guard then
# short-circuits without touching the network at all. A cache miss (first
# call anywhere, or the cache file is absent/unreadable) falls through to
# the same live discovery as before, unchanged.

dx_runtime_docker_host_identity() {
    if [ -z "${DXE_RUNTIME_DOCKER_DAEMON_ID:-}" ]; then
        local cached
        if cached="$(dx_runtime_docker_daemon_id_cache_read 2>/dev/null)" && [ -n "$cached" ]; then
            DXE_RUNTIME_DOCKER_DAEMON_ID="$cached"
            export DXE_RUNTIME_DOCKER_DAEMON_ID
        fi
    fi
    dx_runtime_docker_discover_daemon_id || return 1
    printf 'docker-ssh:%s:%s\n' "$DX_REMOTE_HOST" "$DXE_RUNTIME_DOCKER_DAEMON_ID"
}

# A profile identifies "this docker-ssh profile" for collision detection
# (qnap-dxe-plan.md DQ6's io.dxe.profile) -- computable from plain resolved
# config fields, no remote call needed. Distinct from
# dx_runtime_docker_host_identity's daemon-ID-based identity (item 7's
# concern: telling two DIFFERENT remote daemons apart even if their alias
# were reused); this is "which DXE profile," not "which physical NAS."
dx_runtime_docker_profile_id() {
    printf '%s__%s' "${DX_REMOTE_HOST:?}" "${DX_CONTAINER_NAME:?}"
}

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

