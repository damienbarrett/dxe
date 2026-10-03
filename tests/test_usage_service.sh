#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "Usage service launcher and watchdog (guest scripts/lib/dx-usage-service.sh)"

GUEST_SCRIPTS="$CONTAINER_DIR/scripts"
LIB="$GUEST_SCRIPTS/lib/dx-usage-service.sh"
ENTRY="$GUEST_SCRIPTS/dx-usage-service.sh"
assert_file_exists "$LIB" "the usage-service library exists"
assert_file_exists "$ENTRY" "the usage-service dispatcher exists"
if bash -c 'before=$-; source "$1"; [ "$before" = "$-" ]' _ "$LIB" 2>&1 | grep -q .; then
    test_fail "the usage-service library is side-effect-free when sourced"
else
    test_pass "the usage-service library is side-effect-free when sourced"
fi

fx="$(mktemp -d "${TMPDIR:-/tmp}/dxe-usage-svc.XXXXXX")"
trap 'rm -rf "$fx"' EXIT
export HOME="$fx/home"; mkdir -p "$HOME"
bin="$fx/bin"; mkdir -p "$bin"
export US_LOG="$fx/log"
root="$fx/persist/services/agent-stats"
ai_state="$fx/ai-state"
mkdir -p "$ai_state/current/profile/bin"

# Fake package: one release store path holding both wrappers, which record
# their argv, working directory, PATH and keyring address, then exit.
release="$fx/store/agent-stats-release"
mkdir -p "$release/bin"
for impl in rust python; do
    cat > "$release/bin/agent-stats-$impl" <<'PKG'
#!/bin/bash
{
    printf 'exe=%s\n' "${0##*/}"
    printf 'argv:'; printf ' <%s>' "$@"; printf '\n'
    printf 'pwd=%s\npath=%s\ndbus=%s\ntmux=%s\nrecorder=%s\n' "$PWD" "$PATH" "${DBUS_SESSION_BUS_ADDRESS:-}" "${TMUX_TMPDIR:-}" "${AGENT_STATS_RECORDER_PATH:-unset}"
} >> "$US_LOG"
PKG
    chmod +x "$release/bin/agent-stats-$impl"
done

# Library under test, with the keyring and sleep faked at their seams.
fake_address="unix:path=$fx/fake-bus"
us_serve() {
    # $1 = root. Runs the real serve in a subshell (its exec replaces it).
    : > "$US_LOG"
    (
        source "$GUEST_SCRIPTS/lib/dx-keyring.sh"
        source "$LIB"
        dx_keyring_start() { printf 'keyring-start\n' >> "$US_LOG"; return "${US_KEYRING_STATUS:-0}"; }
        dx_keyring_read_address() { [ "${US_KEYRING_STATUS:-0}" = 0 ] || return 1; printf '%s\n' "$fake_address"; }
        us_sleep() { printf 'sleep:%s\n' "$1" >> "$US_LOG"; }
        export DX_USAGE_SLEEP=us_sleep DX_USAGE_SERVICE_ROOT="$1" DX_AI_STATE_ROOT="$ai_state" DX_KEYRING_ADDRESS_FILE="$fx/keyring-address"
        dx_usage_service_serve
    ) > "$fx/serve.out" 2>&1
}

# --- serve: normal path -----------------------------------------------------
mkdir -p "$root"
ln -s "$release" "$root/current"
us_serve "$root" && us_status=0 || us_status=$?
if grep -qx 'exe=agent-stats-rust' "$US_LOG" \
    && grep -qxF 'argv: <--serve> <--bind> <0.0.0.0:8787> <--interval> <900>' "$US_LOG"; then
    test_pass "serve execs current/bin/agent-stats-rust --serve --bind 0.0.0.0:8787 --interval 900 by default"
else
    test_fail "serve execs current/bin/agent-stats-rust with the service argv (log: $(cat "$US_LOG"); out: $(cat "$fx/serve.out"))"
fi
grep -qx "pwd=$(cd "$root/workspace" && pwd)" "$US_LOG" \
    && test_pass "serve runs from the persisted workspace directory" \
    || test_fail "serve runs from the persisted workspace directory (log: $(cat "$US_LOG"))"
grep -q "^path=$ai_state/current/profile/bin:" "$US_LOG" \
    && test_pass "serve prepends the active dx-ai generation's profile/bin to PATH" \
    || test_fail "serve prepends the active dx-ai generation's profile/bin to PATH (log: $(cat "$US_LOG"))"
grep -qx "dbus=$fake_address" "$US_LOG" && grep -qx 'keyring-start' "$US_LOG" \
    && test_pass "serve starts or reuses the keyring and exports the validated bus address to the package" \
    || test_fail "serve starts or reuses the keyring and exports the validated address (log: $(cat "$US_LOG"))"
grep -qx "tmux=$root/workspace/tmux" "$US_LOG" && [ -d "$root/workspace/tmux" ] \
    && grep -qx 'recorder=unset' "$US_LOG" \
    && test_pass "serve namespaces any tmux state under the workspace (TMUX_TMPDIR) and never sets AGENT_STATS_RECORDER_PATH" \
    || test_fail "serve namespaces tmux state under the workspace and leaves AGENT_STATS_RECORDER_PATH alone (log: $(cat "$US_LOG"))"
all_dirs=true; for d in config workspace data logs; do [ -d "$root/$d" ] || all_dirs=false; done
[ "$all_dirs" = true ] && test_pass "serve creates config, workspace, data and logs under the service root" || test_fail "serve creates config, workspace, data and logs"
[ "$(cat "$root/config/implementation")" = rust ] \
    && test_pass "serve seeds config/implementation with rust when absent" \
    || test_fail "serve seeds config/implementation with rust when absent"
[ ! -e "$root/previous" ] && [ ! -L "$root/previous" ] \
    && test_pass "serve never creates the previous link (release selection owns both links)" \
    || test_fail "serve never creates the previous link"

# --- serve: repeat run, config respected -------------------------------------
printf 'python\n' > "$root/config/implementation"
other_release="$fx/store/older"; mkdir -p "$other_release"; ln -sfn "$other_release" "$root/previous"
us_serve "$root" || true
if grep -qx 'exe=agent-stats-python' "$US_LOG" && [ "$(cat "$root/config/implementation")" = python ] \
    && [ "$(readlink "$root/previous")" = "$other_release" ]; then
    test_pass "a repeat run selects Python from config, keeps the config and leaves an existing previous link alone"
else
    test_fail "a repeat run selects Python from config and keeps existing state (log: $(cat "$US_LOG"))"
fi
: > "$root/config/implementation"
us_serve "$root" || true
if grep -qx 'exe=agent-stats-rust' "$US_LOG" && [ ! -s "$root/config/implementation" ]; then
    test_pass "an empty config/implementation means rust and is not rewritten"
else
    test_fail "an empty config/implementation means rust and is not rewritten (log: $(cat "$US_LOG"))"
fi
printf 'ruby\n' > "$root/config/implementation"
us_serve "$root" && us_status=0 || us_status=$?
if [ "$us_status" -ne 0 ] && ! grep -q '^exe=' "$US_LOG" && grep -qx 'sleep:30' "$US_LOG" \
    && grep -qF "'ruby'" "$fx/serve.out"; then
    test_pass "an unknown implementation fails clearly after a 30 s bounded sleep, never starting a package"
else
    test_fail "an unknown implementation fails clearly after a bounded sleep (status $us_status, log: $(cat "$US_LOG"), out: $(cat "$fx/serve.out"))"
fi
printf 'rust\n' > "$root/config/implementation"

# --- serve: keyring trouble does not stop the service -------------------------
US_KEYRING_STATUS=1 us_serve "$root" || true
if grep -qx 'exe=agent-stats-rust' "$US_LOG" && grep -qx 'dbus=' "$US_LOG" && grep -qF "keyring" "$fx/serve.out"; then
    test_pass "a keyring failure warns and still starts the service (provider rows report it)"
else
    test_fail "a keyring failure warns and still starts the service (log: $(cat "$US_LOG"), out: $(cat "$fx/serve.out"))"
fi

# --- serve: no usable release --------------------------------------------------
for scenario in absent dangling no-executable not-executable; do
    sroot="$fx/persist-$scenario"; mkdir -p "$sroot"
    case "$scenario" in
        absent) ;;
        dangling) ln -s "$fx/store/nowhere" "$sroot/current" ;;
        no-executable) mkdir -p "$fx/store/empty-rel/bin"; ln -s "$fx/store/empty-rel" "$sroot/current" ;;
        not-executable) mkdir -p "$fx/store/plain-rel/bin"; : > "$fx/store/plain-rel/bin/agent-stats-rust"; ln -s "$fx/store/plain-rel" "$sroot/current" ;;
    esac
    us_serve "$sroot" && us_status=0 || us_status=$?
    if [ "$us_status" -ne 0 ] && ! grep -q '^exe=' "$US_LOG" && grep -qx 'sleep:30' "$US_LOG" \
        && grep -qF "$sroot/current/bin/agent-stats-rust" "$fx/serve.out"; then
        test_pass "serve with current $scenario fails clearly, naming the path, after a 30 s sleep (no hot loop)"
    else
        test_fail "serve with current $scenario fails clearly after a 30 s sleep (status $us_status, log: $(cat "$US_LOG"), out: $(cat "$fx/serve.out"))"
    fi
    [ ! -e "$sroot/previous" ] && test_pass "serve with current $scenario creates no previous link" || test_fail "serve with current $scenario creates no previous link"
done

# --- watchdog -------------------------------------------------------------------
write_tool() { printf '#!/bin/bash\n%s\n' "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
write_tool curl 'printf "%s\n" "$*" >> "$US_CURL"
code="$(head -n 1 "$US_CODES" 2>/dev/null)"; [ -n "$code" ] || code=200
sed -i.bak 1d "$US_CODES" 2>/dev/null; rm -f "$US_CODES.bak"
printf "%s" "$code"
[ "$code" != 000 ] || exit 7'
write_tool s6-svc 'printf "s6-svc:" >> "$US_LOG"; printf " <%s>" "$@" >> "$US_LOG"; printf "\n" >> "$US_LOG"'
export US_CURL="$fx/curl.log" US_CODES="$fx/codes"
us_watch() {
    # $1 = iterations, rest = codes returned by successive progress probes.
    local iterations="$1"; shift
    : > "$US_LOG"; : > "$US_CURL"; : > "$US_CODES"
    local c; for c in "$@"; do printf '%s\n' "$c" >> "$US_CODES"; done
    (
        source "$LIB"
        us_sleep() { printf 'sleep:%s\n' "$1" >> "$US_LOG"; }
        PATH="$bin:/usr/bin:/bin"
        export DX_USAGE_SLEEP=us_sleep DX_USAGE_WATCHDOG_MAX_ITERATIONS="$iterations" DX_USAGE_SCAN_DIR="$fx/scan"
        dx_usage_service_watchdog
    ) > "$fx/watch.out" 2>&1
}
us_watch 3 200 200 200 && w=0 || w=$?
if [ "$(grep -c . "$US_CURL")" -eq 3 ] && ! grep -v -F 'http://127.0.0.1:8787/health/progress' "$US_CURL" | grep -q . \
    && ! grep -q '^s6-svc' "$US_LOG" && [ "$(grep -c '^sleep:30$' "$US_LOG")" -eq 3 ]; then
    test_pass "a healthy /health/progress is polled every 30 s and never restarts anything (and /health/ready is never queried)"
else
    test_fail "a healthy /health/progress is polled every 30 s without restarts (curl: $(cat "$US_CURL"); log: $(cat "$US_LOG"))"
fi
us_watch 1 503 || true
if [ "$(grep -c '^s6-svc' "$US_LOG")" -eq 1 ] && grep -qxF "s6-svc: <-r> <$fx/scan/agent-stats>" "$US_LOG" \
    && grep -qx 'sleep:60' "$US_LOG"; then
    test_pass "a 503 from /health/progress restarts only agent-stats (s6-svc -r) and then waits a 60 s cooldown"
else
    test_fail "a 503 from /health/progress restarts only agent-stats then cools down (log: $(cat "$US_LOG"))"
fi
# Provider failures never reach the watchdog as a failing progress probe, and
# /health/ready is not part of its contract: only the progress URL is requested.
us_watch 2 200 200 || true
! grep -q 'ready' "$US_CURL" && ! grep -q '^s6-svc' "$US_LOG" \
    && test_pass "a pending /health/ready or provider error rows never restart the service (the watchdog only reads progress)" \
    || test_fail "the watchdog must not act on readiness or provider errors"
# Unreachable server (process hung or not listening): grace, then restart.
us_watch 7 000 000 000 000 000 000 200 || true
if [ "$(grep -c '^s6-svc' "$US_LOG")" -eq 1 ] && ! sed -n '1,/^s6-svc/p' "$US_LOG" | grep -c '^sleep:30$' | grep -qv '^5$'; then
    test_pass "an unreachable server is restarted only after six consecutive failed probes (a process exit is also restarted by s6-supervise itself)"
else
    test_fail "an unreachable server is restarted only after six consecutive failed probes (log: $(cat "$US_LOG"))"
fi
us_watch 4 000 000 200 000 || true
! grep -q '^s6-svc' "$US_LOG" \
    && test_pass "a healthy probe resets the unreachable count" \
    || test_fail "a healthy probe resets the unreachable count (log: $(cat "$US_LOG"))"
# Consecutive restarts back off: 60, 120, 240 ... capped at 900.
us_watch 6 503 503 503 503 503 503 || true
if [ "$(grep '^sleep:' "$US_LOG" | tr '\n' ' ')" = "sleep:60 sleep:120 sleep:240 sleep:480 sleep:900 sleep:900 " ]; then
    test_pass "consecutive restarts back off 60, 120, 240, 480 s and cap at 900 s"
else
    test_fail "consecutive restarts back off and cap at 900 s (sleeps: $(grep '^sleep:' "$US_LOG" | tr '\n' ' '))"
fi
us_watch 3 503 200 503 || true
if [ "$(grep '^sleep:' "$US_LOG" | tr '\n' ' ')" = "sleep:60 sleep:30 sleep:60 " ]; then
    test_pass "a healthy probe resets the restart back-off"
else
    test_fail "a healthy probe resets the restart back-off (sleeps: $(grep '^sleep:' "$US_LOG" | tr '\n' ' '))"
fi

# Missing tools fail clearly with a bounded sleep (never a hot restart loop).
for missing in curl s6-svc; do
    hide="$fx/bin-no-$missing"; mkdir -p "$hide"
    for t in "$bin"/*; do [ "${t##*/}" = "$missing" ] || ln -sf "$t" "$hide/${t##*/}"; done
    : > "$US_LOG"
    (
        source "$LIB"
        us_sleep() { printf 'sleep:%s\n' "$1" >> "$US_LOG"; }
        PATH="$hide"; export DX_USAGE_SLEEP=us_sleep
        dx_usage_service_watchdog
    ) > "$fx/watch.out" 2>&1 && w=0 || w=$?
    if [ "$w" -ne 0 ] && grep -qx 'sleep:30' "$US_LOG" && grep -qF "'$missing'" "$fx/watch.out" && ! grep -q '^s6-svc' "$US_LOG"; then
        test_pass "the watchdog with $missing missing fails clearly after a 30 s sleep and probes nothing"
    else
        test_fail "the watchdog with $missing missing fails clearly after a 30 s sleep (status $w, log: $(cat "$US_LOG"), out: $(cat "$fx/watch.out"))"
    fi
done

# --- dispatcher ---------------------------------------------------------------------
for args in "" "bogus" "serve extra"; do
    # shellcheck disable=SC2086
    out="$(bash "$ENTRY" $args 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 64 ] && printf '%s\n' "$out" | grep -q 'Usage: dx-usage-service'; then
        test_pass "the dispatcher refuses '${args:-<none>}' with usage and status 64"
    else
        test_fail "the dispatcher refuses '${args:-<none>}' with usage and status 64 (status $rc, out: $out)"
    fi
done

print_summary
exit_with_code
