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

fx="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir fx "${TMPDIR:-/tmp}/dxe-usage-svc.XXXXXX"
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
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
        source "$LIB"
        dx_keyring_start() { printf 'keyring-start\n' >> "$US_LOG"; printf 'dbus-daemon-resolves=%s\n' "$(command -v dbus-daemon || echo none)" >> "$US_LOG"; return "${US_KEYRING_STATUS:-0}"; }
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
all_dirs=true; for d in config workspace data logs control; do [ -d "$root/$d" ] || all_dirs=false; done
[ "$all_dirs" = true ] && test_pass "serve creates config, workspace, data and logs under the service root" || test_fail "serve creates config, workspace, data and logs"
[ "$(cat "$root/config/implementation")" = rust ] \
    && test_pass "serve seeds config/implementation with rust when absent" \
    || test_fail "serve seeds config/implementation with rust when absent"
[ ! -e "$root/previous" ] && [ ! -L "$root/previous" ] \
    && test_pass "serve never creates the previous link (release selection owns both links)" \
    || test_fail "serve never creates the previous link"

# The keyring tools live in the active dx-ai generation, not dx's own profile:
# serve must put that generation's profile/bin on PATH BEFORE starting the keyring.
printf '#!/bin/sh\nexit 0\n' > "$ai_state/current/profile/bin/dbus-daemon"; chmod +x "$ai_state/current/profile/bin/dbus-daemon"
us_serve "$root" || true
if grep -qx "dbus-daemon-resolves=$ai_state/current/profile/bin/dbus-daemon" "$US_LOG" && grep -qx "dbus=$fake_address" "$US_LOG" && grep -qx 'exe=agent-stats-rust' "$US_LOG"; then
    test_pass "serve finds dbus-daemon in the active dx-ai generation (PATH set before the keyring starts), exports the bus address and starts the service"
else
    test_fail "serve resolves dbus-daemon from the active generation before starting the keyring (log: $(cat "$US_LOG"))"
fi
rm -f "$ai_state/current/profile/bin/dbus-daemon"
# No generation at all: the keyring cannot start, the service still does.
mv "$ai_state/current" "$ai_state/current.off"
US_KEYRING_STATUS=1 us_serve "$root" || true
# Portable: a runner may have a real dbus-daemon on PATH, so only require that it
# does NOT come from the (absent) generation, not that nothing resolves.
if ! grep -q "dbus-daemon-resolves=$ai_state" "$US_LOG" && grep -q '^dbus-daemon-resolves=' "$US_LOG" \
    && grep -qx 'exe=agent-stats-rust' "$US_LOG" && grep -qF "keyring is unavailable" "$fx/serve.out"; then
    test_pass "with no dx-ai generation the keyring warning is printed and the service still starts"
else
    test_fail "with no dx-ai generation the service still starts with a warning (log: $(cat "$US_LOG"); out: $(cat "$fx/serve.out"))"
fi
mv "$ai_state/current.off" "$ai_state/current"

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
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
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
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
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

# Any other HTTP status (a proxy answer, a 404 from a mismatched package) is
# neither healthy nor a restart trigger: it resets the unreachable count.
us_watch 8 000 000 000 000 000 404 000 000 || true
! grep -q '^s6-svc' "$US_LOG" \
    && test_pass "an unexpected status resets the unreachable count and never restarts"  \
    || test_fail "an unexpected status resets the unreachable count and never restarts (log: $(cat "$US_LOG"))"
# In-process dispatch (the subprocess runs below are not line-traced).
for args in "bogus" "serve extra" "watchdog extra" ""; do
    # shellcheck disable=SC2086
    # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
    ( source "$LIB"; dx_usage_service_main $args ) >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 64 ] && test_pass "dx_usage_service_main refuses '${args:-<none>}' with status 64" \
        || test_fail "dx_usage_service_main refuses '${args:-<none>}' with status 64 (got $rc)"
done
# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
( source "$LIB"; dx_usage_service_serve() { echo served; }; dx_usage_service_watchdog() { echo watched; }
  [ "$(dx_usage_service_main serve)" = served ] && [ "$(dx_usage_service_main watchdog)" = watched ] ) \
    && test_pass "dx_usage_service_main dispatches serve and watchdog" || test_fail "dx_usage_service_main dispatches serve and watchdog"

# --- dx-ai hook (scripts/lib/dx-ai-post-install.sh) ---------------------------------
# No sudo anywhere: the hook (as dx) leaves $root/control/restart, which the root
# watchdog consumes. A failed request or check is reported loudly, never rolled
# back and never turned into a dx-ai failure (the AI update itself succeeded).
hook_scan="$fx/hook-scan"; mkdir -p "$hook_scan/agent-stats"
hook_root="$fx/hook-root"; mkdir -p "$hook_root"
write_tool curl 'printf "%s\n" "$*" >> "$US_CURL"
code="$(head -n 1 "$US_CODES" 2>/dev/null)"; [ -n "$code" ] || code=200
sed -i.bak 1d "$US_CODES" 2>/dev/null; rm -f "$US_CODES.bak"
printf "%s" "$code"
[ "$code" != 000 ] || exit 7'
run_hook() {
    # $1 = what the fake sleep does: "consume" removes the restart file (as the
    # watchdog would) on its first call; "keep" never consumes it. Rest = command.
    local mode="$1"; shift
    : > "$US_LOG"; : > "$US_CURL"
    (
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-ai-post-install.sh
        source "$GUEST_SCRIPTS/lib/dx-ai-post-install.sh"
        sudo() { printf 'sudo:%s\n' "$*" >> "$US_LOG"; }
        hook_sleep() { printf 'sleep:%s\n' "$1" >> "$US_LOG"; [ "$mode" != consume ] || rm -f "$hook_root/control/restart"; }
        dx_ai_usage_service_compat_check() { printf 'compat:%s\ncompat-root:%s\n' "$1" "${2:-}" >> "$US_LOG"; }
        PATH="${US_HOOK_PATH:-$bin:/usr/bin:/bin}"
        export DX_USAGE_SCAN_DIR="$hook_scan" DX_USAGE_SERVICE_ROOT="$hook_root" DX_USAGE_SLEEP=hook_sleep
        "$@"
    ) > "$fx/hook.out" 2>&1
}
rm -rf "$hook_root/control"
printf '000\n000\n200\n' > "$US_CODES"
run_hook consume dx_ai_usage_service_hook "$fx/state"; h=$?
if [ "$h" -eq 0 ] && grep -qx 'sleep:2' "$US_LOG" && ! grep -q '^sudo:' "$US_LOG" \
    && [ ! -e "$hook_root/control/restart" ] && [ -d "$hook_root/control" ] \
    && grep -qF "restart requested" "$fx/hook.out" && grep -qx "compat:$fx/state/current" "$US_LOG"; then
    test_pass "the hook requests a restart through the control file (no sudo), waits for it to be picked up and the service to answer, then runs the compatibility check"
else
    test_fail "the hook requests a restart through the control file and then checks compatibility (rc $h; log: $(cat "$US_LOG"); out: $(cat "$fx/hook.out"))"
fi
# While nobody consumes the request, the file is the proof of the request.
rm -rf "$hook_root/control"; printf '200\n' > "$US_CODES"
run_hook keep dx_ai_usage_service_hook "$fx/state"; h=$?
if [ "$h" -eq 0 ] && [ -f "$hook_root/control/restart" ] && [ "$(grep -c '^sleep:2$' "$US_LOG")" -eq 30 ] \
    && ! grep -q '^compat:' "$US_LOG" && grep -qF "did not come back" "$fx/hook.out" && grep -qF "no rollback" "$fx/hook.out"; then
    test_pass "an unpicked request or a service that does not return within 60 s is reported (no rollback), skips the compatibility check and still succeeds"
else
    test_fail "an unpicked request is reported after 60 s (rc $h; sleeps: $(grep -c '^sleep:2$' "$US_LOG"); out: $(cat "$fx/hook.out"))"
fi
# Picked up, but the service never answers.
rm -rf "$hook_root/control"; : > "$US_CODES"; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do echo 000 >> "$US_CODES"; done
run_hook consume dx_ai_usage_service_hook "$fx/state"; h=$?
if [ "$h" -eq 0 ] && ! grep -q '^compat:' "$US_LOG" && grep -qF "did not come back" "$fx/hook.out"; then
    test_pass "a service that never answers /health/live is reported and skips the compatibility check"
else
    test_fail "a service that never answers is reported (rc $h; out: $(cat "$fx/hook.out"))"
fi
# No curl: skip the wait, say so, still run the check.
rm -rf "$hook_root/control"; no_curl="$fx/bin-no-curl-hook"; mkdir -p "$no_curl"; for t in bash mkdir mktemp mv rm cat; do ln -sf "$(command -v $t)" "$no_curl/$t"; done
US_HOOK_PATH="$no_curl" run_hook keep dx_ai_usage_service_hook "$fx/state"; h=$?
if [ "$h" -eq 0 ] && [ -f "$hook_root/control/restart" ] && grep -qF "curl is not available" "$fx/hook.out" && grep -qx "compat:$fx/state/current" "$US_LOG" && ! grep -q '^sleep:' "$US_LOG"; then
    test_pass "without curl the hook skips the wait, says so, and still runs the compatibility check"
else
    test_fail "without curl the hook skips the wait (rc $h; log: $(cat "$US_LOG"); out: $(cat "$fx/hook.out"))"
fi
# The control directory cannot be created: reported, no rollback, dx-ai unaffected.
rm -rf "$hook_root/control"; : > "$hook_root/control"
run_hook consume dx_ai_usage_service_hook "$fx/state"; h=$?
if [ "$h" -eq 0 ] && grep -qF "could not request" "$fx/hook.out" && grep -qF "no rollback" "$fx/hook.out" && ! grep -q '^compat:' "$US_LOG"; then
    test_pass "a control directory that cannot be written is reported (no rollback) without failing dx-ai"
else
    test_fail "an unwritable control directory is reported (rc $h; out: $(cat "$fx/hook.out"))"
fi
rm -f "$hook_root/control"
# Outside service mode: nothing at all.
mkdir -p "$fx/no-service-scan"
: > "$US_LOG"
( # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-ai-post-install.sh
  source "$GUEST_SCRIPTS/lib/dx-ai-post-install.sh"; DX_USAGE_SCAN_DIR="$fx/no-service-scan" DX_USAGE_SERVICE_ROOT="$hook_root" dx_ai_usage_service_hook "$fx/state" ) > "$fx/hook.out" 2>&1; h=$?
[ "$h" -eq 0 ] && [ ! -s "$fx/hook.out" ] && [ ! -e "$hook_root/control" ] \
    && test_pass "outside service mode the hook prints nothing and creates nothing" \
    || test_fail "outside service mode the hook prints nothing and creates nothing (rc $h; out: $(cat "$fx/hook.out"))"
# --- dx-ai compatibility check (dx_ai_usage_service_compat_check) ---------------------
# The check sources the launcher's library (dx_usage_service_implementation) from its
# own directory, so these runs use the real parser. The package and the provider
# CLIs are fakes: the wrappers record argv and PATH, the providers record any run
# (they must only ever be RESOLVED, never executed), and `timeout` is a fake that
# records its bound and can answer 124. Nothing reaches a network or a real guest.
cc_state="$fx/cc-state"; cc_prof="$cc_state/current/profile/bin"; cc_root="$fx/cc-root"; cc_rel="$fx/cc-release"
cc_bin="$fx/cc-bin"; mkdir -p "$cc_prof" "$cc_root/config" "$cc_rel/bin" "$cc_bin"
ln -sf "$(command -v cat)" "$cc_bin/cat"
cat > "$cc_bin/timeout" <<'TMO'
#!/bin/bash
[ -z "${US_TIMEOUT_RC:-}" ] || exit "$US_TIMEOUT_RC"
printf 'timeout:%s\n' "$1" >> "$US_LOG"
shift
exec "$@"
TMO
chmod +x "$cc_bin/timeout"
for impl in rust python; do
    cat > "$cc_rel/bin/agent-stats-$impl" <<'PKG'
#!/bin/bash
printf 'exe=%s argv=%s path=%s\n' "${0##*/}" "$*" "$PATH" >> "$US_LOG"
printf 'Usage: agent-stats\nsecond help line\n'
exit "$(cat "$US_HELP_RC" 2>/dev/null || echo 0)"
PKG
    chmod +x "$cc_rel/bin/agent-stats-$impl"
done
cc_providers() { # $@ = provider names to (re)create in the new generation's profile/bin
    rm -f "$cc_prof"/claude "$cc_prof"/codex "$cc_prof"/agy
    local n; for n in "$@"; do printf '#!/bin/bash\nprintf "provider-ran:%%s\\n" "${0##*/}" >> "$US_LOG"\n' > "$cc_prof/$n"; chmod +x "$cc_prof/$n"; done
}
export US_HELP_RC="$fx/help-rc"
run_cc() { # runs the check against $cc_state/$cc_root; output in $fx/cc.out
    : > "$US_LOG"
    (
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-ai-post-install.sh
        source "$GUEST_SCRIPTS/lib/dx-ai-post-install.sh"
        PATH="$cc_bin"
        dx_ai_usage_service_compat_check "$cc_state/current" "$cc_root"
    ) > "$fx/cc.out" 2>&1 && cc_rc=0 || cc_rc=$?
}
ln -sfn "$cc_rel" "$cc_root/current"; cc_providers claude codex agy; rm -f "$US_HELP_RC"
run_cc
if [ "$cc_rc" -eq 0 ] && grep -qx 'timeout:10' "$US_LOG" && grep -q "^exe=agent-stats-rust argv=--help path=$cc_prof:" "$US_LOG" \
    && ! grep -q '^provider-ran:' "$US_LOG" && [ "$(wc -l < "$fx/cc.out" | tr -d ' ')" -eq 1 ] && grep -qF "passed" "$fx/cc.out"; then
    test_pass "the compatibility check runs current/bin/agent-stats-rust --help (bounded, new generation's profile/bin first on PATH), resolves the provider CLIs without running them, and prints one line"
else
    test_fail "the compatibility check passes with a good release (rc $cc_rc; log: $(cat "$US_LOG"); out: $(cat "$fx/cc.out"))"
fi
printf 'python\n' > "$cc_root/config/implementation"
run_cc
if [ "$cc_rc" -eq 0 ] && grep -q '^exe=agent-stats-python argv=--help' "$US_LOG" && ! grep -q '^exe=agent-stats-rust' "$US_LOG"; then
    test_pass "the compatibility check follows config/implementation (python selects agent-stats-python)"
else
    test_fail "the compatibility check follows config/implementation (rc $cc_rc; log: $(cat "$US_LOG"); out: $(cat "$fx/cc.out"))"
fi
: > "$cc_root/config/implementation"; run_cc; empty_rc=$cc_rc; empty_log="$(cat "$US_LOG")"
rm -f "$cc_root/config/implementation"; run_cc
if [ "$empty_rc" -eq 0 ] && [ "$cc_rc" -eq 0 ] && printf '%s\n' "$empty_log" | grep -q '^exe=agent-stats-rust ' && grep -q '^exe=agent-stats-rust ' "$US_LOG"; then
    test_pass "an empty or absent config/implementation means rust in the compatibility check"
else
    test_fail "an empty or absent config/implementation means rust (rc $empty_rc/$cc_rc; log: $(cat "$US_LOG"))"
fi
printf 'ruby\n' > "$cc_root/config/implementation"
run_cc
if [ "$cc_rc" -ne 0 ] && grep -qF "'ruby'" "$fx/cc.out" && grep -qF "no rollback was performed" "$fx/cc.out" && ! grep -q '^exe=' "$US_LOG"; then
    test_pass "an unknown implementation fails the compatibility check with a warning (no rollback) and runs no package"
else
    test_fail "an unknown implementation fails the compatibility check (rc $cc_rc; out: $(cat "$fx/cc.out"))"
fi
rm -f "$cc_root/config/implementation"
printf '1\n' > "$US_HELP_RC"; run_cc
if [ "$cc_rc" -ne 0 ] && grep -qF "agent-stats-rust --help" "$fx/cc.out" && grep -qF "exit 1" "$fx/cc.out" && grep -qF "no rollback was performed" "$fx/cc.out" \
    && grep -qF "Usage: agent-stats" "$fx/cc.out" && ! grep -qF "second help line" "$fx/cc.out"; then
    test_pass "a wrapper whose --help exits 1 fails the check with a warning (no rollback) that keeps only the first output line"
else
    test_fail "a failing --help is reported with one output line (rc $cc_rc; out: $(cat "$fx/cc.out"))"
fi
rm -f "$US_HELP_RC"
US_TIMEOUT_RC=124 run_cc
if [ "$cc_rc" -ne 0 ] && grep -qF "no answer within 10s" "$fx/cc.out" && grep -qF "no rollback was performed" "$fx/cc.out"; then
    test_pass "a --help that does not answer within the bound fails the check with a warning (no rollback)"
else
    test_fail "a --help that times out is reported (rc $cc_rc; out: $(cat "$fx/cc.out"))"
fi
chmod -x "$cc_rel/bin/agent-stats-rust"; run_cc; chmod +x "$cc_rel/bin/agent-stats-rust"
if [ "$cc_rc" -ne 0 ] && grep -qF "$cc_root/current/bin/agent-stats-rust is missing or not executable" "$fx/cc.out" && grep -qF "no rollback was performed" "$fx/cc.out" && ! grep -q '^exe=' "$US_LOG"; then
    test_pass "a release whose wrapper is not executable fails the check with a warning naming it (no rollback)"
else
    test_fail "a non-executable wrapper is reported (rc $cc_rc; out: $(cat "$fx/cc.out"))"
fi
rm -f "$cc_root/current"; run_cc; absent_rc=$cc_rc; absent_out="$(cat "$fx/cc.out")"
ln -sfn "$fx/cc-no-such-release" "$cc_root/current"; run_cc
if [ "$absent_rc" -ne 0 ] && [ "$cc_rc" -ne 0 ] && [ "$(printf '%s\n' "$absent_out" | grep -c "$cc_root/current")" -eq 1 ] \
    && [ "$(grep -c "$cc_root/current" "$fx/cc.out")" -eq 1 ] && grep -qF "no release is linked at $cc_root/current" "$fx/cc.out" \
    && printf '%s\n' "$absent_out" | grep -qF "no release is linked at $cc_root/current" && grep -qF "no rollback was performed" "$fx/cc.out" && [ "$(wc -l < "$fx/cc.out" | tr -d ' ')" -eq 1 ]; then
    test_pass "no current release (absent or dangling link) gives one warning naming the link (no rollback)"
else
    test_fail "no current release gives one warning naming the link (rc $absent_rc/$cc_rc; out: $absent_out | $(cat "$fx/cc.out"))"
fi
ln -sfn "$cc_rel" "$cc_root/current"
for missing in claude codex agy; do
    others=""; for n in claude codex agy; do [ "$n" = "$missing" ] || others="$others $n"; done
    # shellcheck disable=SC2086
    cc_providers $others; run_cc
    if [ "$cc_rc" -ne 0 ] && [ "$(grep -c "provider CLI" "$fx/cc.out")" -eq 1 ] && grep -qF "'$missing'" "$fx/cc.out" && grep -qF "no rollback was performed" "$fx/cc.out"; then
        test_pass "a missing $missing fails the check with one warning naming it (no rollback)"
    else
        test_fail "a missing $missing is reported (rc $cc_rc; out: $(cat "$fx/cc.out"))"
    fi
done
cc_providers; run_cc
if [ "$cc_rc" -ne 0 ] && [ "$(grep -c "provider CLI" "$fx/cc.out")" -eq 3 ] && grep -qF "'claude'" "$fx/cc.out" && grep -qF "'codex'" "$fx/cc.out" && grep -qF "'agy'" "$fx/cc.out"; then
    test_pass "each missing provider CLI is its own warning line"
else
    test_fail "each missing provider CLI is its own warning line (rc $cc_rc; out: $(cat "$fx/cc.out"))"
fi
# A provider found only further down the PATH than the new generation still counts
# (the new generation's profile/bin goes FIRST, it does not replace the rest).
mkdir -p "$fx/cc-extra"; printf '#!/bin/bash\nexit 0\n' > "$fx/cc-extra/agy"; chmod +x "$fx/cc-extra/agy"
cc_providers claude codex
( source "$GUEST_SCRIPTS/lib/dx-ai-post-install.sh"; PATH="$cc_bin:$fx/cc-extra"; : > "$US_LOG"; dx_ai_usage_service_compat_check "$cc_state/current" "$cc_root" ) > "$fx/cc.out" 2>&1 && cc_rc=0 || cc_rc=$?
[ "$cc_rc" -eq 0 ] && test_pass "a provider CLI further down the PATH still resolves (the new generation goes first, not alone)" \
    || test_fail "a provider CLI further down the PATH resolves (rc $cc_rc; out: $(cat "$fx/cc.out"))"
# The library that supplies the implementation parser must be next to the check, or it says so
# (the copy in cc-lone-lib has no sibling dx-usage-service.sh).
cc_providers claude codex agy
mkdir -p "$fx/cc-lone-lib"; cp "$GUEST_SCRIPTS/lib/dx-ai-post-install.sh" "$fx/cc-lone-lib/"
( source "$fx/cc-lone-lib/dx-ai-post-install.sh"; PATH="$cc_bin"; dx_ai_usage_service_compat_check "$cc_state/current" "$cc_root" ) > "$fx/cc.out" 2>&1 && cc_rc=0 || cc_rc=$?
if [ "$cc_rc" -ne 0 ] && grep -qF "usage-service library is unavailable" "$fx/cc.out" && grep -qF "no rollback was performed" "$fx/cc.out"; then
    test_pass "an unloadable usage-service library fails the check with a warning (no rollback)"
else
    test_fail "an unloadable usage-service library is reported (rc $cc_rc; out: $(cat "$fx/cc.out"))"
fi
# The hook hands the check the generation link and the service root.
rm -rf "$hook_root/control"; printf '200\n' > "$US_CODES"
run_hook consume dx_ai_usage_service_hook "$fx/state"
grep -qx "compat-root:$hook_root" "$US_LOG" \
    && test_pass "the hook passes the service root to the compatibility check" \
    || test_fail "the hook passes the service root to the compatibility check (log: $(cat "$US_LOG"))"
hook_failing_check() {
    # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-ai-post-install.sh
    source "$GUEST_SCRIPTS/lib/dx-ai-post-install.sh"
    dx_ai_usage_service_compat_check() { return 3; }
    DX_USAGE_SCAN_DIR="$hook_scan" DX_USAGE_SERVICE_ROOT="$hook_root" DX_USAGE_SLEEP=hook_sleep2 dx_ai_usage_service_hook "$1"
}
hook_sleep2() { rm -f "$hook_root/control/restart"; }
printf '200\n' > "$US_CODES"; rm -rf "$hook_root/control"
( PATH="$bin:/usr/bin:/bin"; hook_failing_check "$fx/state" ) > "$fx/hook.out" 2>&1; h=$?
if [ "$h" -eq 0 ] && grep -qF "compatibility check failed" "$fx/hook.out" && grep -qF "no rollback" "$fx/hook.out"; then
    test_pass "a failed compatibility check is reported loudly with no rollback, and dx-ai still succeeds"
else
    test_fail "a failed compatibility check is reported loudly with no rollback (rc $h; out: $(cat "$fx/hook.out"))"
fi

# --- watchdog consumes the control file --------------------------------------------
rm -rf "$fx/wroot"; mkdir -p "$fx/wroot/control"; : > "$fx/wroot/control/restart"
us_watch_root() {
    local iterations="$1"; shift
    : > "$US_LOG"; : > "$US_CURL"; : > "$US_CODES"
    local c; for c in "$@"; do printf '%s\n' "$c" >> "$US_CODES"; done
    (
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
        source "$LIB"
        us_sleep() { printf 'sleep:%s\n' "$1" >> "$US_LOG"; }
        PATH="$bin:/usr/bin:/bin"
        export DX_USAGE_SLEEP=us_sleep DX_USAGE_WATCHDOG_MAX_ITERATIONS="$iterations" DX_USAGE_SCAN_DIR="$fx/scan" DX_USAGE_SERVICE_ROOT="$fx/wroot"
        dx_usage_service_watchdog
    ) > "$fx/watch.out" 2>&1
}
us_watch_root 1 || true
if [ ! -e "$fx/wroot/control/restart" ] && [ "$(grep -c '^s6-svc' "$US_LOG")" -eq 1 ] \
    && grep -qxF "s6-svc: <-r> <$fx/scan/agent-stats>" "$US_LOG" && [ ! -s "$US_CURL" ] \
    && [ "$(grep '^sleep:' "$US_LOG" | tr '\n' ' ')" = "sleep:30 " ]; then
    test_pass "the watchdog consumes control/restart: file removed, s6-svc -r on agent-stats once, no probe and no cooldown that iteration"
else
    test_fail "the watchdog consumes control/restart (log: $(cat "$US_LOG"); curl: $(cat "$US_CURL"))"
fi
# A requested restart is not a watchdog restart: the next real one still gets the first (60 s) cooldown.
: > "$fx/wroot/control/restart"
us_watch_root 2 503 || true
if [ "$(grep '^sleep:' "$US_LOG" | tr '\n' ' ')" = "sleep:30 sleep:60 " ] && [ "$(grep -c '^s6-svc' "$US_LOG")" -eq 2 ]; then
    test_pass "a requested restart is not counted for the watchdog's back-off"
else
    test_fail "a requested restart is not counted for the back-off (log: $(cat "$US_LOG"))"
fi
# No request file: unchanged behaviour (covered above); a missing control directory is fine.
rm -rf "$fx/wroot"
us_watch_root 1 200 || true
! grep -q '^s6-svc' "$US_LOG" && test_pass "without a control directory the watchdog behaves exactly as before" || test_fail "without a control directory the watchdog behaves as before"

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
