#!/usr/bin/env bash
# Shared usage-service launcher and watchdog logic. Safe to source.
#
# scripts/dx-usage-service.sh is a thin dispatcher over these functions; it is
# started by the s6 services bootstrap/usage-service.sh builds (`serve` as dx,
# `watchdog` as root). The caller sources scripts/lib/dx-keyring.sh first.
#
# Release layout (docs/refactor/usage-service-host.md design item 4): under
# /persist/services/agent-stats, `current` and `previous` link to one build of
# the combined flake output agent-stats-release (bin/agent-stats-rust,
# bin/agent-stats-python, bin/check-limits, share/agent-stats/*), and
# config/implementation holds `rust` (default, also when absent or empty) or
# `python`. The package itself is installed by a separate session; this code
# only runs what `current` points at and never builds or installs anything.
#
# Delays are bounded and every sleep goes through ${DX_USAGE_SLEEP:-sleep} so
# tests can observe them without waiting.

DX_USAGE_FAIL_DELAY=30            # seconds slept before a launcher/watchdog start failure exits
DX_USAGE_PROBE_INTERVAL=30        # seconds between /health/progress probes
DX_USAGE_DOWN_LIMIT=6             # consecutive unreachable probes before a restart (3 minutes)
DX_USAGE_COOLDOWN=60              # first wait after a restart, doubling per consecutive restart
DX_USAGE_COOLDOWN_MAX=900         # ... capped here

dx_usage_service_sleep() { "${DX_USAGE_SLEEP:-sleep}" "$1"; }

# Prints "Error: ..." and waits out the bounded delay, then fails: s6 restarts
# a failing run script at once, so the delay is what stops a hot loop.
dx_usage_service_fail() {
    echo "Error: $1" >&2
    dx_usage_service_sleep "$DX_USAGE_FAIL_DELAY"
    return 1
}

# Reads config/implementation (absent or empty means rust); prints rust|python.
dx_usage_service_implementation() {
    local file="$1/config/implementation" value=""
    [ ! -f "$file" ] || IFS= read -r value < "$file" || true
    case "$value" in
        ""|rust) printf 'rust\n' ;;
        python) printf 'python\n' ;;
        *) echo "Error: config/implementation says '$value'; expected rust or python." >&2; return 1 ;;
    esac
}

# Creates the state directories and seeds config defaults only when absent. The
# `current` and `previous` links belong to release selection (runbook) and are
# never created here.
dx_usage_service_prepare_state() {
    local root="$1" d
    for d in config workspace data logs control workspace/tmux; do mkdir -p "$root/$d" || return 1; done
    [ -e "$root/config/implementation" ] || printf 'rust\n' > "$root/config/implementation" || return 1
}

# True (0) when connecting to the socket NAME (relative to the current directory)
# is refused or fails outright. curl is the probe because the dx profile
# guarantees it (guest-tools.nix) and nothing else that can connect to a unix
# socket is guaranteed (no perl, socat or nc), and tmux cannot tell a dead
# socket from a foreign listener. curl exit 7 is "could not connect"; any other
# outcome (a reply, an empty reply from a listener that closes at once, a
# timeout on a full backlog) means something answered, so the socket is kept.
dx_usage_service_tmux_socket_dead() {
    local rc=0
    curl -q -s -o /dev/null --max-time 2 --unix-socket "$1" http://localhost/ || rc=$?
    [ "$rc" -eq 7 ]
}

# Runs in a subshell of the caller: removes the dead sockets among the direct
# children of the validated directory DIR. Each is probed by relative name from
# inside DIR (a unix socket path is limited to about 104 bytes).
dx_usage_service_prune_children() {
    local dir="$1" entry removed=0 failed=0
    cd "$dir" || return 1
    for entry in ./* ./.[!.]* ./..?*; do
        { [ -S "$entry" ] && [ ! -L "$entry" ]; } || continue
        dx_usage_service_tmux_socket_dead "$entry" || continue
        if rm -f -- "$entry"; then removed=$((removed + 1)); else
            echo "Error: could not remove stale tmux socket $dir/${entry#./}." >&2; failed=1
        fi
    done
    [ "$removed" -eq 0 ] || echo "Pruned $removed stale tmux socket(s) from $dir" >&2
    [ "$failed" -eq 0 ]
}

# Removes the dead sockets that are direct children of DIR, which must be
# "<...>/workspace/tmux/tmux-<id -u>" (the directory TMUX_TMPDIR names for this
# uid); anything else is refused before a single file is touched. Every scrape
# of the agent-stats package starts its own tmux server on a unique socket, and
# a server killed without its exit path leaves the socket file behind for ever.
# Only sockets (never symlinks, directories or files) that refuse a connection
# are removed; one stderr line reports how many.
dx_usage_service_prune_tmux_sockets() {
    local dir="$1" uid
    uid="$(id -u)"
    case "$dir" in
        /*) : ;;
        *) echo "Error: refusing to prune tmux sockets in '$dir': not an absolute path." >&2; return 1 ;;
    esac
    case "$dir" in
        */./*|*/../*|*/.|*/..) echo "Error: refusing to prune tmux sockets in '$dir': it has a . or .. component." >&2; return 1 ;;
    esac
    case "$dir" in
        */workspace/tmux/tmux-"$uid") : ;;
        *) echo "Error: refusing to prune tmux sockets in '$dir': expected a path ending in /workspace/tmux/tmux-$uid." >&2; return 1 ;;
    esac
    [ -e "$dir" ] || [ -L "$dir" ] || return 0
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        echo "Error: refusing to prune tmux sockets in '$dir': not a real directory." >&2
        return 1
    fi
    command -v curl >/dev/null 2>&1 || { echo "Error: cannot prune tmux sockets in $dir: curl is missing." >&2; return 1; }
    # A subshell, so the caller keeps its directory.
    ( dx_usage_service_prune_children "$dir" )
}

# Launcher: runs as dx, ends in `exec` of the selected wrapper in the foreground.
dx_usage_service_serve() {
    local root="${DX_USAGE_SERVICE_ROOT:-/persist/services/agent-stats}"
    local ai_state="${DX_AI_STATE_ROOT:-/persist/home/dx/.local/state/dx-ai}"
    local address_file="${DX_KEYRING_ADDRESS_FILE:-/persist/home/dx/.local/state/dx/keyring-address}"
    local implementation executable address

    dx_usage_service_prepare_state "$root" || { dx_usage_service_fail "could not prepare $root."; return 1; }
    implementation="$(dx_usage_service_implementation "$root")" || { dx_usage_service_sleep "$DX_USAGE_FAIL_DELAY"; return 1; }
    executable="$root/current/bin/agent-stats-$implementation"
    [ -f "$executable" ] && [ -x "$executable" ] || {
        dx_usage_service_fail "no usable agent-stats release: $executable is missing or not executable. Link a release at $root/current first."
        return 1
    }

    # The active dx-ai generation's tools (dbus-daemon, the keyring, the provider
    # CLIs) are not in dx's own profile, so its profile/bin goes on PATH before
    # the keyring starts, not after.
    [ ! -d "$ai_state/current/profile/bin" ] || export PATH="$ai_state/current/profile/bin:$PATH"
    # The keyring is shared with dx-ai; a failure is reported but must not keep
    # the service down (provider rows show the missing secrets instead).
    if dx_keyring_start "$address_file" >&2 && address="$(dx_keyring_read_address "$address_file")"; then
        export DBUS_SESSION_BUS_ADDRESS="$address"
    else
        echo "Warning: the keyring is unavailable; providers that need it will report errors." >&2
    fi
    # Any tmux the package starts is namespaced under its own workspace, so
    # stopping the service can never reach another tmux server.
    export TMUX_TMPDIR="$root/workspace/tmux"
    # Sockets of tmux servers killed without their exit path (see the prune function).
    dx_usage_service_prune_tmux_sockets "$root/workspace/tmux/tmux-$(id -u)" || echo "Warning: could not prune stale tmux sockets." >&2
    cd "$root/workspace" || { dx_usage_service_fail "cannot enter $root/workspace."; return 1; }
    exec "$executable" --serve --bind 0.0.0.0:8787 --interval 900
}

# One health probe: prints the HTTP status of /health/progress ("000" when the
# server is unreachable). Only this endpoint is ever read.
dx_usage_service_probe() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${DX_USAGE_HEALTH_URL:-http://127.0.0.1:8787/health/progress}")" || true
    printf '%s\n' "${code:-000}"
}

# Watchdog: runs as root. Restarts only the agent-stats service (s6-svc -r on
# its own service directory) when /health/progress answers 503, or when the
# server stays unreachable for DX_USAGE_DOWN_LIMIT probes in a row (a process
# that merely exited is restarted by s6-supervise itself; this catches one that
# is alive but not serving). /health/ready and provider errors never matter.
dx_usage_service_watchdog() {
    local scan_dir="${DX_USAGE_SCAN_DIR:-/run/dx-services}" max="${DX_USAGE_WATCHDOG_MAX_ITERATIONS:-0}"
    local control_file="${DX_USAGE_SERVICE_ROOT:-/persist/services/agent-stats}/control/restart"
    local tool code iteration=0 down=0 restarts=0 wait cooldown
    for tool in curl s6-svc; do
        command -v "$tool" >/dev/null 2>&1 || {
            dx_usage_service_fail "the watchdog needs '$tool' on PATH but it is missing."
            return 1
        }
    done
    while [ "$max" -eq 0 ] || [ "$iteration" -lt "$max" ]; do
        iteration=$((iteration + 1))
        # A restart requested by the dx-ai hook (as dx, who cannot run s6-svc):
        # consume it and restart agent-stats at once. It is not a health failure,
        # so no probe, no cooldown and no back-off count this iteration.
        if [ -e "$control_file" ]; then
            rm -f "$control_file"
            echo "Watchdog: restart requested through $control_file; restarting agent-stats." >&2
            s6-svc -r "$scan_dir/agent-stats" || echo "Warning: s6-svc -r failed." >&2
            down=0
            dx_usage_service_sleep "$DX_USAGE_PROBE_INTERVAL"
            continue
        fi
        code="$(dx_usage_service_probe)"
        wait="$DX_USAGE_PROBE_INTERVAL"
        case "$code" in
            200) down=0; restarts=0 ;;
            503) down=0; wait=restart ;;
            000) down=$((down + 1)); [ "$down" -lt "$DX_USAGE_DOWN_LIMIT" ] || wait=restart ;;
            *) down=0 ;;
        esac
        if [ "$wait" = restart ]; then
            echo "Watchdog: /health/progress answered $code; restarting agent-stats." >&2
            s6-svc -r "$scan_dir/agent-stats" || echo "Warning: s6-svc -r failed." >&2
            cooldown=$DX_USAGE_COOLDOWN
            local n=0
            while [ "$n" -lt "$restarts" ] && [ "$cooldown" -lt "$DX_USAGE_COOLDOWN_MAX" ]; do cooldown=$((cooldown * 2)); n=$((n + 1)); done
            [ "$cooldown" -le "$DX_USAGE_COOLDOWN_MAX" ] || cooldown=$DX_USAGE_COOLDOWN_MAX
            restarts=$((restarts + 1)); down=0
            wait=$cooldown
        fi
        dx_usage_service_sleep "$wait"
    done
}

dx_usage_service_usage() { echo "Usage: dx-usage-service <serve|watchdog>"; }

dx_usage_service_main() {
    case "${1:-}" in
        serve) [ "$#" -eq 1 ] || { dx_usage_service_usage >&2; return 64; }; dx_usage_service_serve ;;
        watchdog) [ "$#" -eq 1 ] || { dx_usage_service_usage >&2; return 64; }; dx_usage_service_watchdog ;;
        *) dx_usage_service_usage >&2; return 64 ;;
    esac
}
