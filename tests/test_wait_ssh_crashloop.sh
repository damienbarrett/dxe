#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
test_section "dx-wait-ssh fails fast on a crash-looping guest (restart count and runtime queries)"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-wait-crashloop.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export HOME="$fixture/home" DX_PROFILES_DIR="$fixture/profiles"
mkdir -p "$HOME" "$DX_PROFILES_DIR"
unset XDG_STATE_HOME

source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
source "$BASE_DIR/bin/lib/dx-tunnel.sh"
source "$BASE_DIR/bin/lib/dx-backup.sh"

# --- the runtime query, on both adapters -----------------------------------------
new_tool_dir() {
    local dir
    dir="$(fake_tool_dir_create "$fixture")"
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    fake_qnap_ssh_write "$dir"
    [ -x "$dir/ssh" ] || { echo "test setup: fake ssh missing in $dir" >&2; exit 1; }
    printf '%s' "$dir"
}
export RC_LOG="$fixture/docker.log"
dir="$(new_tool_dir)"
fake_tool_write "$dir" docker 'old=$IFS; IFS="|"; printf "%s\n" "$*" >> "$RC_LOG"; IFS=$old
printf "3\r\n"'
: > "$RC_LOG"
rc_out="$( ( PATH="$dir:/usr/bin:/bin"; DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-wait; export DXE_RUNTIME_DOCKER_BIN=docker DX_GUEST_SYSTEM=x86_64-linux; dx_runtime_container_restart_count dx-wait ) 2>&1 )" || true
if [ "$rc_out" = 3 ] && [ "$(cat "$RC_LOG")" = "container|inspect|--format|{{.RestartCount}}|dx-wait" ]; then
    test_pass "docker-ssh: dx_runtime_container_restart_count runs docker container inspect --format {{.RestartCount}} and prints the bare number"
else
    test_fail "docker-ssh: dx_runtime_container_restart_count (out: '$rc_out'; argv: $(cat "$RC_LOG"))"
fi
dir="$(new_tool_dir)"; fake_tool_write "$dir" docker 'exit 1'
if ( PATH="$dir:/usr/bin:/bin"; DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid; export DXE_RUNTIME_DOCKER_BIN=docker DX_GUEST_SYSTEM=x86_64-linux; dx_runtime_container_restart_count dx-wait ) >/dev/null 2>&1; then
    test_fail "docker-ssh: an unknown container makes the restart-count query fail"
else
    test_pass "docker-ssh: an unknown container makes the restart-count query fail"
fi
dir="$(new_tool_dir)"; fake_tool_write "$dir" container 'echo "container called" >> "$RC_LOG"; exit 99'
: > "$RC_LOG"
ap_out="$( ( PATH="$dir:/usr/bin:/bin"; DX_RUNTIME=apple; dx_runtime_container_restart_count dx-wait ) 2>&1 )" || true
if [ "$ap_out" = 0 ] && [ ! -s "$RC_LOG" ]; then
    test_pass "apple: the restart count is 0 and no container CLI call is made (Apple has no restart policy)"
else
    test_fail "apple: the restart count is 0 without a CLI call (out: '$ap_out'; log: $(cat "$RC_LOG"))"
fi

# --- the wait loop (bin/dx-wait-ssh with a stubbed runtime) -------------------------
mkdir -p "$fixture/bin"
cp "$BASE_DIR/bin/dx-wait-ssh" "$fixture/bin/"
cat > "$fixture/bin/dx-lib.sh" <<LIB
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
dx_require_container_cli() { :; }
container_exists() { return 0; }
container_is_running() { [ "\${WS_RUNNING:-yes}" = yes ]; }
# The probe counter drives the scenario: the Nth failed probe is call N.
dx_ssh_probe_login_shell() {
    local n; n=\$(( \$(cat "\$WS_STATE/probes" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$WS_STATE/probes"
    [ "\$n" -ge "\${WS_SUCCEED_AT:-99999}" ]
}
dx_runtime_container_restart_count() {
    local n; n=\$(cat "\$WS_STATE/probes" 2>/dev/null || echo 0)
    echo "\$((\${WS_COUNT_BASE:-0} + n * \${WS_COUNT_STEP:-0} / \${WS_COUNT_DIV:-1}))"
}
dx_runtime_logs() { printf 'logs %s\n' "\$*" >> "\$WS_STATE/runtime.log"; printf 'bootstrap line\n'; }
LIB
export DX_CONTAINER_NAME=dx-wait DX_SSH_WAIT_TIMEOUT=4 DX_SSH_POLL_INTERVAL=1 DX_SSH_PROGRESS_INTERVAL=100000 DX_SLEEP=true
ws_run() {
    export WS_STATE="$fixture/state"; rm -rf "$WS_STATE"; mkdir -p "$WS_STATE"
    ws_rc=0; ws_out="$( "$fixture/bin/dx-wait-ssh" 2>&1 )" || ws_rc=$?
}
# Healthy: flat count, SSH answers on the third probe -> unchanged behaviour.
WS_SUCCEED_AT=3 WS_COUNT_STEP=0 ws_run
if [ "$ws_rc" -eq 0 ] && printf '%s\n' "$ws_out" | grep -qF "Guest is ready." && ! printf '%s\n' "$ws_out" | grep -qi "crash-loop\|Error"; then
    test_pass "a healthy start (running, restart count flat) waits as before and succeeds"
else
    test_fail "a healthy start waits as before (rc $ws_rc; out: $ws_out)"
fi
# One restart is tolerated (a transient failure that recovered).
WS_SUCCEED_AT=4 WS_COUNT_STEP=1 WS_COUNT_DIV=3 ws_run
if [ "$ws_rc" -eq 0 ] && printf '%s\n' "$ws_out" | grep -qF "Guest is ready."; then
    test_pass "a single restart during the wait is tolerated"
else
    test_fail "a single restart during the wait is tolerated (rc $ws_rc; out: $ws_out)"
fi
# Restart count +2: abort with the condition, 20 log lines and the advice.
WS_COUNT_BASE=4 WS_COUNT_STEP=1 ws_run
if [ "$ws_rc" -eq 1 ] && printf '%s\n' "$ws_out" | grep -qF "crash-looping" \
    && printf '%s\n' "$ws_out" | grep -qF "restart count rose from 4 to 6" \
    && printf '%s\n' "$ws_out" | grep -qF "Last 20 container log lines:" && printf '%s\n' "$ws_out" | grep -qF "bootstrap line" \
    && grep -qx "logs -n 20 dx-wait" "$WS_STATE/runtime.log" \
    && printf '%s\n' "$ws_out" | grep -qF "dx-recreate" && printf '%s\n' "$ws_out" | grep -qF "profile" \
    && [ "$(cat "$WS_STATE/probes")" -le 4 ]; then
    test_pass "a restart count that rises by two aborts the wait, naming the condition, printing the last 20 log lines and what to check (dx-recreate after fixing)"
else
    test_fail "a restart count +2 aborts the wait with logs and advice (rc $ws_rc; probes $(cat "$WS_STATE/probes" 2>/dev/null); out: $ws_out)"
fi
# Container exited: the existing abort, now through the shared function.
WS_RUNNING=no ws_run
if [ "$ws_rc" -eq 1 ] && printf '%s\n' "$ws_out" | grep -qF "stopped before SSH became responsive" \
    && printf '%s\n' "$ws_out" | grep -qF "Last 80 container log lines:" && grep -qx "logs -n 80 dx-wait" "$WS_STATE/runtime.log"; then
    test_pass "a container that is no longer running aborts the wait exactly as before (80 log lines)"
else
    test_fail "a container that is no longer running aborts the wait (rc $ws_rc; out: $ws_out)"
fi
# A runtime that cannot report a count never aborts the wait.
WS_SUCCEED_AT=3 ws_run
sed -i.bak 's/^dx_runtime_container_restart_count() {$/dx_runtime_container_restart_count() { return 1; }\nzz_unused() {/' "$fixture/bin/dx-lib.sh"; rm -f "$fixture/bin/dx-lib.sh.bak"
WS_SUCCEED_AT=3 ws_run
if [ "$ws_rc" -eq 0 ] && printf '%s\n' "$ws_out" | grep -qF "Guest is ready."; then
    test_pass "an unavailable restart count never aborts the wait"
else
    test_fail "an unavailable restart count never aborts the wait (rc $ws_rc; out: $ws_out)"
fi

print_summary
exit_with_code
