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

    # The keyring is shared with dx-ai; a failure is reported but must not keep
    # the service down (provider rows show the missing secrets instead).
    if dx_keyring_start "$address_file" >&2 && address="$(dx_keyring_read_address "$address_file")"; then
        export DBUS_SESSION_BUS_ADDRESS="$address"
    else
        echo "Warning: the keyring is unavailable; providers that need it will report errors." >&2
    fi
    [ ! -d "$ai_state/current/profile/bin" ] || export PATH="$ai_state/current/profile/bin:$PATH"
    # Any tmux the package starts is namespaced under its own workspace, so
    # stopping the service can never reach another tmux server.
    export TMUX_TMPDIR="$root/workspace/tmux"
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
