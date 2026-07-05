#!/bin/bash
# Section 9: Host Script Architecture
# Tests for: set -euo pipefail, configurable constants, idempotence,
# layer separation, error handling, consistent logging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$BASE_DIR/bin"

test_section "Section 9: Host Script Architecture"

# Test: All scripts have set -euo pipefail
for script in "$BIN_DIR"/dx-*; do
    if [ -f "$script" ]; then
        script_name=$(basename "$script")
        if grep -q "set -euo pipefail" "$script"; then
            test_pass "$script_name has set -euo pipefail"
        else
            test_fail "$script_name has set -euo pipefail"
        fi
    fi
done

# Test: dx-create-container uses configurable constants
DX_CREATE_CONTAINER="$BIN_DIR/dx-create-container"
if grep -q "DX_CONTAINER_NAME\|DX_IMAGE\|DX_SSH_PORT\|DX_SSH_KEY" "$DX_CREATE_CONTAINER"; then
    test_pass "dx-create-container uses environment variables for constants"
else
    test_fail "dx-create-container uses environment variables for constants"
fi

# Test: dx-status uses container list (not ls if unreliable)
DX_STATUS="$BIN_DIR/dx-status"
if grep -q "container list\|container ls" "$DX_STATUS"; then
    test_pass "dx-status uses container list/ls"
else
    test_fail "dx-status uses container list/ls"
fi

# Test: Bash syntax check for all scripts
SYNTAX_FAILED=0
for script in "$BIN_DIR"/dx-*; do
    if [ -f "$script" ]; then
        if ! bash -n "$script" 2>/dev/null; then
            SYNTAX_FAILED=$((SYNTAX_FAILED + 1))
            test_fail "$(basename "$script") passes bash -n syntax check"
        fi
    fi
done
if [ "$SYNTAX_FAILED" -eq 0 ]; then
    test_pass "All scripts pass bash -n syntax check"
fi

# Test: bootstrap.sh also passes syntax check
if bash -n "$BOOTSTRAP" 2>/dev/null; then
    test_pass "bootstrap.sh passes bash -n syntax check"
else
    test_fail "bootstrap.sh passes bash -n syntax check"
fi

# -----------------------------------------------------------------------------
# dx-ssh assertions
# -----------------------------------------------------------------------------

DX_SSH="$BIN_DIR/dx-ssh"
if grep -q "if.*DX_SSH_KEY\|if.*dx_key" "$DX_SSH" || grep -q "test -f.*DX_SSH_KEY\|\[ -f.*DX_SSH_KEY" "$DX_SSH" || grep -q "\[ ! -f \"\$DX_SSH_KEY\" \]" "$DX_SSH"; then
    test_pass "dx-ssh checks if SSH key file exists"
else
    test_fail "dx-ssh checks if SSH key file exists"
fi

if grep -q "command -v tmux" "$DX_SSH" && grep -q "tmux is not available yet" "$DX_SSH"; then
    test_pass "dx-ssh checks tmux before attaching"
else
    test_fail "dx-ssh checks tmux before attaching"
fi

if grep -q "dx-theme-restore" "$DX_SSH"; then
    test_pass "dx-ssh restores theme before tmux attach"
else
    test_fail "dx-ssh restores theme before tmux attach"
fi

if grep -q '\.nix-profile/bin' "$DX_SSH"; then
    test_pass "dx-ssh adds guest Nix profile to PATH"
else
    test_fail "dx-ssh adds guest Nix profile to PATH"
fi

assert_file_contains "$DX_SSH" "LogLevel=ERROR" "dx-ssh suppresses noisy known-host warnings"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_SSH_CONNECT_TIMEOUT=.*15" "dx-lib exposes 15s SSH connect timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_BOOTSTRAP_WAIT_TIMEOUT=.*30" "dx-lib exposes bootstrap marker wait timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GUEST_ACTIVATION_TIMEOUT=.*1800" "dx-lib exposes a 30-minute guest activation timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GUEST_ACTIVATION_ATTEMPTS=.*2" "dx-lib exposes guest activation attempts"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GUEST_ACTIVATION_RETRY_DELAY=.*5" "dx-lib exposes guest activation retry delay"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GIT_MOUNT_SOURCE=.*:-" "dx-lib defaults git mount source to empty"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GIT_MOUNT_TARGET=.*workspace" "dx-lib exposes git mount target"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_CONTAINER_MEMORY" "dx-lib exposes configurable container memory"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_CONTAINER_CPUS" "dx-lib exposes configurable container CPU count"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_derived_name" "dx-lib provides derived side-container names"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_require_non_reserved_container_name" "dx-lib reserves dx-host centrally"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_port_in_use" "dx-lib provides a loopback port probe"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_get_host_timezone" "dx-lib centralizes host timezone detection"
assert_file_contains "$BIN_DIR/dx-lib.sh" "defaulting guest timezone to UTC" "dx-lib defaults timezone detection to UTC instead of empty"
assert_file_contains "$DX_CREATE_CONTAINER" "HOST_TZ=\"UTC\"" "dx-create-container guards against an empty host timezone"
assert_file_contains "$DX_CREATE_CONTAINER" "DX_GUEST_ACTIVATION_TIMEOUT" "dx-create-container passes activation timeout into the guest"
assert_file_contains "$DX_CREATE_CONTAINER" "DX_GUEST_ACTIVATION_ATTEMPTS" "dx-create-container passes activation attempts into the guest"
assert_file_contains "$DX_CREATE_CONTAINER" "DX_GUEST_ACTIVATION_RETRY_DELAY" "dx-create-container passes activation retry delay into the guest"
HOST_TZ_PROBE="$(dx_get_host_timezone 2>/dev/null || true)"
if [ -n "$HOST_TZ_PROBE" ]; then
    test_pass "dx_get_host_timezone returns a non-empty timezone"
else
    test_fail "dx_get_host_timezone returns a non-empty timezone"
fi
assert_file_contains "$DX_SSH" "ConnectTimeout=\$DX_SSH_CONNECT_TIMEOUT" "dx-ssh uses a bounded connect timeout"
assert_file_contains "$DX_SSH" "DX_GUEST_WORKDIR" "dx-ssh supports optional profile workdir"

DX_WAIT_SSH="$BIN_DIR/dx-wait-ssh"
assert_file_contains "$DX_WAIT_SSH" "container_is_running" "dx-wait-ssh detects bootstrap container exits"
assert_file_contains "$DX_WAIT_SSH" "Last 80 container log lines" "dx-wait-ssh prints recent container logs on SSH wait failure"

# A factory-reset bootstrap may use every bounded activation attempt. The host
# wait budget must cover that complete guest-side budget rather than expiring
# after the first attempt.
DX_DEFAULT_SSH_WAIT="$(
    DX_GUEST_ACTIVATION_TIMEOUT=10 \
    DX_GUEST_ACTIVATION_ATTEMPTS=2 \
    DX_GUEST_ACTIVATION_RETRY_DELAY=3 \
        bash -c 'source "$1"; dx_default_ssh_wait_timeout' _ "$BIN_DIR/dx-lib.sh" 2>/dev/null || true
)"
if [[ "$DX_DEFAULT_SSH_WAIT" =~ ^[0-9]+$ ]] && [ "$DX_DEFAULT_SSH_WAIT" -gt 1823 ]; then
    test_pass "default SSH wait covers guest activation plus fresh bootstrap overhead"
else
    test_fail "default SSH wait covers guest activation plus fresh bootstrap overhead"
fi

# Behavioural coverage for dx-wait-ssh uses command stubs, so it cannot mutate
# the real Apple container runtime or wait in real time.
DX_WAIT_TEST_TMP="$(mktemp -d)"
DX_WAIT_STUB_BIN="$DX_WAIT_TEST_TMP/bin"
DX_WAIT_SSH_COUNT="$DX_WAIT_TEST_TMP/ssh-count"
mkdir -p "$DX_WAIT_STUB_BIN"

cat > "$DX_WAIT_STUB_BIN/container" <<'EOF'
#!/bin/bash
set -euo pipefail

case "${1:-} ${2:-}" in
    "list -a")
        printf 'ID STATE\n'
        printf '%s stopped\n' "${DX_CONTAINER_NAME:-dx-host}"
        ;;
    "list ")
        printf 'ID STATE\n'
        if [ "${DX_STUB_CONTAINER_STATE:-running}" = "running" ]; then
            printf '%s running\n' "${DX_CONTAINER_NAME:-dx-host}"
        fi
        ;;
    "logs -n")
        printf 'copying path test-package from cache.nixos.org\n'
        ;;
    *)
        echo "Unexpected container stub arguments: $*" >&2
        exit 2
        ;;
esac
EOF

cat > "$DX_WAIT_STUB_BIN/ssh" <<'EOF'
#!/bin/bash
set -euo pipefail

# Optional artificial per-call delay so tests can simulate a slow/hanging SSH
# probe. Defaults to 0 (no delay) so every existing behavioral test is
# unaffected. `sleep` here is real (no stub overrides it below), so this
# consumes actual wall-clock time -- exactly what a hanging ssh would do.
sleep "${DX_STUB_SSH_DELAY:-0}"

count=0
if [ -f "$DX_WAIT_SSH_COUNT" ]; then
    count="$(cat "$DX_WAIT_SSH_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$DX_WAIT_SSH_COUNT"

if [ "$count" -le "${DX_STUB_SSH_FAILURES:-0}" ]; then
    exit 255
fi
EOF

# No `sleep` stub: dx-wait-ssh's monotonic deadline is measured against real
# elapsed time (bash's SECONDS builtin), so its own `sleep "$SLEEP_INTERVAL"`
# calls must actually consume wall-clock time for that accounting to mean
# anything. Falls through to the real system `sleep` later in PATH.
chmod +x "$DX_WAIT_STUB_BIN/container" "$DX_WAIT_STUB_BIN/ssh"

dx_wait_behavior() {
    local output_file="$1"
    shift
    rm -f "$DX_WAIT_SSH_COUNT"
    env \
        PATH="$DX_WAIT_STUB_BIN:$PATH" \
        DX_WAIT_SSH_COUNT="$DX_WAIT_SSH_COUNT" \
        DX_SSH_WAIT_TIMEOUT=3 \
        DX_SSH_POLL_INTERVAL=1 \
        DX_SSH_PROGRESS_INTERVAL=1 \
        "$@" \
        "$DX_WAIT_SSH" >"$output_file" 2>&1
}

DX_WAIT_OUTPUT="$DX_WAIT_TEST_TMP/output"
if dx_wait_behavior "$DX_WAIT_OUTPUT" DX_STUB_SSH_FAILURES=0 \
    && grep -q "Guest is ready" "$DX_WAIT_OUTPUT"; then
    test_pass "dx-wait-ssh returns as soon as SSH is responsive"
else
    test_fail "dx-wait-ssh returns as soon as SSH is responsive"
fi

set +e
dx_wait_behavior "$DX_WAIT_OUTPUT" DX_STUB_SSH_FAILURES=99
DX_WAIT_TIMEOUT_STATUS=$?
set -e
DX_WAIT_TIMEOUT_POLLS="$(cat "$DX_WAIT_SSH_COUNT" 2>/dev/null || true)"
# The wait loop's deadline is now real wall-clock time (bash's SECONDS
# builtin), which -- unlike the old sleep-only counter -- truncates to whole
# seconds from an integer epoch snapshot; a probe landing a few milliseconds
# either side of a one-second boundary can shift the observed poll count by
# one. Assert a tolerant range instead of an exact count.
if [ "$DX_WAIT_TIMEOUT_STATUS" -eq 1 ] \
    && [ "$DX_WAIT_TIMEOUT_POLLS" -ge 3 ] && [ "$DX_WAIT_TIMEOUT_POLLS" -le 5 ] \
    && grep -q "after 3s" "$DX_WAIT_OUTPUT" \
    && grep -q "copying path test-package" "$DX_WAIT_OUTPUT"; then
    test_pass "dx-wait-ssh honors its timeout and reports recent guest progress"
else
    test_fail "dx-wait-ssh honors its timeout and reports recent guest progress (polls=$DX_WAIT_TIMEOUT_POLLS)"
fi

set +e
dx_wait_behavior "$DX_WAIT_OUTPUT" \
    DX_STUB_SSH_FAILURES=99 \
    DX_STUB_CONTAINER_STATE=stopped
DX_WAIT_STOPPED_STATUS=$?
set -e
if [ "$DX_WAIT_STOPPED_STATUS" -eq 1 ] \
    && grep -q "stopped before SSH became responsive" "$DX_WAIT_OUTPUT" \
    && grep -q "copying path test-package" "$DX_WAIT_OUTPUT"; then
    test_pass "dx-wait-ssh reports a guest that stops during bootstrap"
else
    test_fail "dx-wait-ssh reports a guest that stops during bootstrap"
fi

if dx_wait_behavior "$DX_WAIT_OUTPUT" DX_STUB_SSH_FAILURES=2 \
    && grep -q "Bootstrap still running" "$DX_WAIT_OUTPUT" \
    && grep -q "copying path test-package" "$DX_WAIT_OUTPUT" \
    && grep -q "Guest is ready" "$DX_WAIT_OUTPUT"; then
    test_pass "dx-wait-ssh shows progress while a fresh bootstrap continues"
else
    test_fail "dx-wait-ssh shows progress while a fresh bootstrap continues"
fi

set +e
dx_wait_behavior "$DX_WAIT_OUTPUT" DX_SSH_WAIT_TIMEOUT=invalid
DX_WAIT_INVALID_STATUS=$?
set -e
if [ "$DX_WAIT_INVALID_STATUS" -eq 1 ] \
    && grep -q "DX_SSH_WAIT_TIMEOUT must be a positive integer" "$DX_WAIT_OUTPUT"; then
    test_pass "dx-wait-ssh rejects an invalid wait timeout"
else
    test_fail "dx-wait-ssh rejects an invalid wait timeout"
fi

# dx-wait-ssh must be bounded by real elapsed (wall-clock) time, not just the
# time it itself spent sleeping. A slow/hanging ssh probe must not multiply
# the effective wait far past DX_SSH_WAIT_TIMEOUT: with a ~2s ssh probe and a
# 3s timeout, sleep-only accounting lets the loop run every poll to its full
# ssh duration on top of every sleep (roughly 4 * 2s + 3 * 1s = 11s here),
# while a correct monotonic deadline stops within about timeout + one poll
# interval + one in-flight ssh overrun (roughly 5s here).
set +e
DX_WAIT_BOUND_START=$SECONDS
dx_wait_behavior "$DX_WAIT_OUTPUT" DX_STUB_SSH_FAILURES=99 DX_STUB_SSH_DELAY=2
DX_WAIT_BOUND_STATUS=$?
DX_WAIT_BOUND_ELAPSED=$((SECONDS - DX_WAIT_BOUND_START))
set -e
if [ "$DX_WAIT_BOUND_STATUS" -ne 0 ] && [ "$DX_WAIT_BOUND_ELAPSED" -lt 7 ]; then
    test_pass "dx-wait-ssh bounds total wait to wall-clock time despite a slow ssh probe"
else
    test_fail "dx-wait-ssh bounds total wait to wall-clock time despite a slow ssh probe (status=$DX_WAIT_BOUND_STATUS elapsed=${DX_WAIT_BOUND_ELAPSED}s)"
fi

rm -rf "$DX_WAIT_TEST_TMP"

if grep -q "base64 -d | bash -l" "$DX_SSH"; then
    test_pass "dx-ssh wraps non-interactive commands for bash"
else
    test_fail "dx-ssh wraps non-interactive commands for bash"
fi

# Test: dx-ai is a guest command, not a host wrapper
assert_file_not_exists "$BIN_DIR/dx-ai" "dx-ai is not installed as a host script"

# -----------------------------------------------------------------------------
# dx-forward
# -----------------------------------------------------------------------------

DX_FORWARD="$BIN_DIR/dx-forward"
assert_file_exists "$DX_FORWARD" "dx-forward helper exists"
assert_file_contains "$DX_FORWARD" "source \"\$SCRIPT_DIR/dx-lib.sh\"" "dx-forward uses shared script library"
assert_file_contains "$DX_FORWARD" "set -euo pipefail" "dx-forward uses strict shell mode"
assert_file_contains "$DX_FORWARD" "ssh -f -N -M" "dx-forward uses a background SSH master"
assert_file_contains "$DX_FORWARD" "ExitOnForwardFailure=yes" "dx-forward fails when a local forward cannot bind"
assert_file_contains "$DX_FORWARD" "127.0.0.1:\${host_port}:127.0.0.1:\${guest_port}" "dx-forward binds host forwards to loopback"
assert_file_contains "$DX_FORWARD" "DX_CONTAINER_NAME" "dx-forward namespaces sockets by configured container"
assert_file_contains "$DX_FORWARD" "DX_SSH_PORT" "dx-forward uses configured SSH port"
assert_file_contains "$DX_FORWARD" "DX_SSH_KEY" "dx-forward uses configured SSH key"
assert_file_contains "$DX_FORWARD" "DX_SSH_CONNECT_TIMEOUT" "dx-forward uses configured SSH connect timeout"
assert_file_contains "$DX_FORWARD" "dx-wait-ssh" "dx-forward waits for guest SSH readiness"
assert_file_contains "$DX_FORWARD" "DX_FORWARD_WAIT_SSH" "dx-forward allows tests to stub SSH readiness waiting"
assert_file_contains "$DX_FORWARD" "container_exists \"\$DX_CONTAINER_NAME\"" "dx-forward verifies the configured container exists"
assert_file_contains "$DX_FORWARD" "container_is_running \"\$DX_CONTAINER_NAME\"" "dx-forward verifies the configured container is running"
assert_file_contains "$DX_FORWARD" "validate_port" "dx-forward validates port arguments"
assert_file_contains "$DX_FORWARD" "port < 1024" "dx-forward rejects privileged host ports"
assert_file_contains "$DX_FORWARD" "dx_port_in_use" "dx-forward detects host port conflicts"
assert_file_contains "$DX_FORWARD" "[[:space:]]--list)" "dx-forward supports listing helper-managed forwards"
assert_file_contains "$DX_FORWARD" "[[:space:]]--stop)" "dx-forward supports stopping one forward"
assert_file_contains "$DX_FORWARD" "[[:space:]]--stop-all)" "dx-forward supports stopping all forwards"
assert_file_contains "$DX_FORWARD" "ssh .* -O check" "dx-forward checks existing control sockets"
assert_file_contains "$DX_FORWARD" "ssh .* -O exit" "dx-forward stops forwards through SSH control sockets"
assert_file_contains "$DX_FORWARD" "Forwarded http://127.0.0.1:" "dx-forward prints a browser URL for opened forwards"

DX_FORWARD_PARSE_OUTPUT="$(DX_FORWARD_TEST_MODE=parse "$DX_FORWARD" 5173 5173:5175 2>/dev/null || true)"
if [ "$DX_FORWARD_PARSE_OUTPUT" = $'5173:5173\n5175:5173' ]; then
    test_pass "dx-forward parses bare and remapped port arguments"
else
    test_fail "dx-forward parses bare and remapped port arguments"
fi

if DX_FORWARD_TEST_MODE=parse "$DX_FORWARD" foo >/dev/null 2>&1; then
    test_fail "dx-forward rejects non-integer ports"
else
    test_pass "dx-forward rejects non-integer ports"
fi

if DX_FORWARD_TEST_MODE=parse "$DX_FORWARD" 80 >/dev/null 2>&1; then
    test_fail "dx-forward rejects privileged host ports"
else
    test_pass "dx-forward rejects privileged host ports"
fi

if DX_FORWARD_TEST_MODE=parse "$DX_FORWARD" 70000 >/dev/null 2>&1; then
    test_fail "dx-forward rejects out-of-range ports"
else
    test_pass "dx-forward rejects out-of-range ports"
fi

DX_FORWARD_BEHAVIOR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dx-forward-behavior.XXXXXX")"
DX_FORWARD_STUB_BIN="$DX_FORWARD_BEHAVIOR_TMP/bin"
DX_FORWARD_SOCKET_TMP="$DX_FORWARD_BEHAVIOR_TMP/tmp"
DX_FORWARD_SSH_LOG="$DX_FORWARD_BEHAVIOR_TMP/ssh.log"
DX_FORWARD_WAIT_LOG="$DX_FORWARD_BEHAVIOR_TMP/wait.log"
DX_FORWARD_KEY="$DX_FORWARD_BEHAVIOR_TMP/dx_key"
trap 'rm -rf "${DX_FORWARD_BEHAVIOR_TMP:-}" "${DX_REVERSE_BEHAVIOR_TMP:-}"' EXIT
mkdir -p "$DX_FORWARD_STUB_BIN" "$DX_FORWARD_SOCKET_TMP"
touch "$DX_FORWARD_KEY"

cat > "$DX_FORWARD_STUB_BIN/container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
    "system status")
        exit 0
        ;;
    "list -a"|"list ")
        printf '%s\n' "${DX_CONTAINER_NAME:-dx-host}"
        exit 0
        ;;
esac

exit 0
EOF
chmod +x "$DX_FORWARD_STUB_BIN/container"

cat > "$DX_FORWARD_STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

socket=""
operation=""
forward=""

selected_port() {
    local candidate="$1"
    local selected="${2:-}"

    case " $selected " in
        *" $candidate "*)
            return 0
            ;;
    esac
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -S)
            socket="$2"
            shift 2
            ;;
        -O)
            operation="$2"
            shift 2
            ;;
        -L)
            forward="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

{
    printf 'operation=%s\n' "$operation"
    printf 'socket=%s\n' "$socket"
    printf 'forward=%s\n' "$forward"
} >> "${DX_FORWARD_SSH_LOG:?}"

case "$operation" in
    check)
        port="${socket%.sock}"
        port="${port##*-}"
        if selected_port "$port" "${DX_STUB_SSH_CHECK_FAIL_PORTS:-}"; then
            exit 1
        fi
        [ -n "$socket" ] && [ -e "$socket" ]
        exit $?
        ;;
    exit)
        port="${socket%.sock}"
        port="${port##*-}"
        if selected_port "$port" "${DX_STUB_SSH_EXIT_FAIL_PORTS:-}"; then
            if selected_port "$port" "${DX_STUB_SSH_EXIT_DISAPPEARS_PORTS:-}"; then
                rm -f "$socket"
            fi
            exit 1
        fi
        rm -f "$socket"
        exit 0
        ;;
esac

if [ -n "$socket" ]; then
    : > "$socket"
fi
exit 0
EOF
chmod +x "$DX_FORWARD_STUB_BIN/ssh"

cat > "$DX_FORWARD_STUB_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
EOF
chmod +x "$DX_FORWARD_STUB_BIN/lsof"

cat > "$DX_FORWARD_STUB_BIN/dx-wait-ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'waited\n' >> "${DX_FORWARD_WAIT_LOG:?}"
EOF
chmod +x "$DX_FORWARD_STUB_BIN/dx-wait-ssh"

dx_forward_behavior() {
    env \
        DX_CONTAINER_NAME=dx-forward-test \
        DX_SSH_PORT=29999 \
        DX_SSH_KEY="$DX_FORWARD_KEY" \
        DX_SSH_CONNECT_TIMEOUT=1 \
        DX_FORWARD_WAIT_SSH="$DX_FORWARD_STUB_BIN/dx-wait-ssh" \
        DX_FORWARD_SSH_LOG="$DX_FORWARD_SSH_LOG" \
        DX_FORWARD_WAIT_LOG="$DX_FORWARD_WAIT_LOG" \
        TMPDIR="$DX_FORWARD_SOCKET_TMP" \
        PATH="$DX_FORWARD_STUB_BIN:$PATH" \
        "$DX_FORWARD" "$@"
}

dx_forward_host_port=31873
dx_forward_attempts=0
while dx_port_in_use "$dx_forward_host_port" 2>/dev/null && [ "$dx_forward_attempts" -lt 100 ]; do
    dx_forward_host_port=$((dx_forward_host_port + 1))
    dx_forward_attempts=$((dx_forward_attempts + 1))
done

dx_forward_socket="$DX_FORWARD_SOCKET_TMP/dx-forward-dx-forward-test-$dx_forward_host_port.sock"
dx_forward_metadata="$dx_forward_socket.meta"
rm -f "$DX_FORWARD_SSH_LOG" "$DX_FORWARD_WAIT_LOG"

DX_FORWARD_START_OUT="$(dx_forward_behavior "5173:$dx_forward_host_port" 2>&1 || true)"
if printf '%s\n' "$DX_FORWARD_START_OUT" | grep -q "Forwarded http://127.0.0.1:$dx_forward_host_port -> dx-forward-test:5173" \
    && [ -e "$dx_forward_socket" ] \
    && grep -qx "host_port=$dx_forward_host_port" "$dx_forward_metadata" \
    && grep -qx "guest_port=5173" "$dx_forward_metadata" \
    && grep -qx "forward=127.0.0.1:${dx_forward_host_port}:127.0.0.1:5173" "$DX_FORWARD_SSH_LOG" \
    && grep -qx "waited" "$DX_FORWARD_WAIT_LOG"; then
    test_pass "dx-forward starts a loopback SSH forward and writes metadata"
else
    test_fail "dx-forward starts a loopback SSH forward and writes metadata"
fi

DX_FORWARD_REPEAT_OUT="$(dx_forward_behavior "5173:$dx_forward_host_port" 2>&1 || true)"
if printf '%s\n' "$DX_FORWARD_REPEAT_OUT" | grep -q "Forward already active http://127.0.0.1:$dx_forward_host_port -> dx-forward-test:5173"; then
    test_pass "dx-forward treats an identical active forward as idempotent"
else
    test_fail "dx-forward treats an identical active forward as idempotent"
fi

if dx_forward_behavior "5174:$dx_forward_host_port" >/dev/null 2>&1; then
    test_fail "dx-forward refuses to retarget an active host port"
else
    test_pass "dx-forward refuses to retarget an active host port"
fi

DX_FORWARD_LIST_OUT="$(dx_forward_behavior --list 2>&1 || true)"
if printf '%s\n' "$DX_FORWARD_LIST_OUT" | grep -q "Active http://127.0.0.1:$dx_forward_host_port -> dx-forward-test:5173"; then
    test_pass "dx-forward lists active forwards from control sockets and metadata"
else
    test_fail "dx-forward lists active forwards from control sockets and metadata"
fi

DX_FORWARD_STOP_OUT="$(dx_forward_behavior --stop "$dx_forward_host_port" 2>&1 || true)"
if printf '%s\n' "$DX_FORWARD_STOP_OUT" | grep -q "Stopped http://127.0.0.1:$dx_forward_host_port" \
    && [ ! -e "$dx_forward_socket" ] \
    && [ ! -e "$dx_forward_metadata" ] \
    && grep -qx "operation=exit" "$DX_FORWARD_SSH_LOG"; then
    test_pass "dx-forward stops an active forward and removes socket metadata"
else
    test_fail "dx-forward stops an active forward and removes socket metadata"
fi

dx_forward_behavior "5173:$dx_forward_host_port" >/dev/null
if DX_STUB_SSH_EXIT_FAIL_PORTS="$dx_forward_host_port" \
    dx_forward_behavior --stop "$dx_forward_host_port" > "$DX_FORWARD_BEHAVIOR_TMP/failed-stop.out" 2>&1; then
    test_fail "dx-forward reports a failed exit while the SSH master remains active"
elif [ -e "$dx_forward_socket" ] \
    && [ -e "$dx_forward_metadata" ] \
    && grep -q "still active" "$DX_FORWARD_BEHAVIOR_TMP/failed-stop.out"; then
    test_pass "dx-forward reports a failed exit while preserving active state"
else
    test_fail "dx-forward reports a failed exit while preserving active state"
fi

if DX_STUB_SSH_EXIT_FAIL_PORTS="$dx_forward_host_port" \
    DX_STUB_SSH_EXIT_DISAPPEARS_PORTS="$dx_forward_host_port" \
    dx_forward_behavior --stop "$dx_forward_host_port" > "$DX_FORWARD_BEHAVIOR_TMP/disappeared-stop.out" 2>&1 \
    && [ ! -e "$dx_forward_socket" ] \
    && [ ! -e "$dx_forward_metadata" ] \
    && grep -q "Stopped http://127.0.0.1:$dx_forward_host_port" "$DX_FORWARD_BEHAVIOR_TMP/disappeared-stop.out"; then
    test_pass "dx-forward cleans state when exit fails after the master disappears"
else
    test_fail "dx-forward cleans state when exit fails after the master disappears"
fi

printf 'container=dx-forward-test\nhost_port=%s\nguest_port=5173\n' \
    "$dx_forward_host_port" > "$dx_forward_metadata"
if dx_forward_behavior --stop "$dx_forward_host_port" > "$DX_FORWARD_BEHAVIOR_TMP/orphan-stop.out" 2>&1 \
    && [ ! -e "$dx_forward_metadata" ] \
    && grep -q "Removed orphan dx-forward metadata" "$DX_FORWARD_BEHAVIOR_TMP/orphan-stop.out"; then
    test_pass "dx-forward explicit stop removes orphan metadata"
else
    test_fail "dx-forward explicit stop removes orphan metadata"
fi

printf 'container=dx-forward-test\nhost_port=%s\nguest_port=5173\n' \
    "$dx_forward_host_port" > "$dx_forward_metadata"
DX_FORWARD_ORPHAN_LIST_OUT="$(dx_forward_behavior --list 2>&1 || true)"
if printf '%s\n' "$DX_FORWARD_ORPHAN_LIST_OUT" | grep -q "Orphan dx-forward metadata for host port $dx_forward_host_port" \
    && ! printf '%s\n' "$DX_FORWARD_ORPHAN_LIST_OUT" | grep -q "Active http://127.0.0.1:$dx_forward_host_port"; then
    test_pass "dx-forward lists orphan metadata without reporting it active"
else
    test_fail "dx-forward lists orphan metadata without reporting it active"
fi
dx_forward_behavior --stop "$dx_forward_host_port" >/dev/null

touch "$dx_forward_socket"
printf 'container=dx-forward-test\nhost_port=%s\nguest_port=5173\n' \
    "$dx_forward_host_port" > "$dx_forward_metadata"
DX_FORWARD_STALE_LIST_OUT="$(
    DX_STUB_SSH_CHECK_FAIL_PORTS="$dx_forward_host_port" dx_forward_behavior --list 2>&1 || true
)"
if printf '%s\n' "$DX_FORWARD_STALE_LIST_OUT" | grep -q "Stale dx-forward socket for host port $dx_forward_host_port" \
    && DX_STUB_SSH_CHECK_FAIL_PORTS="$dx_forward_host_port" \
        dx_forward_behavior --stop "$dx_forward_host_port" >/dev/null \
    && [ ! -e "$dx_forward_socket" ] \
    && [ ! -e "$dx_forward_metadata" ]; then
    test_pass "dx-forward distinguishes and removes stale socket state"
else
    test_fail "dx-forward distinguishes and removes stale socket state"
fi

dx_forward_second_port=$((dx_forward_host_port + 1))
while dx_port_in_use "$dx_forward_second_port" 2>/dev/null; do
    dx_forward_second_port=$((dx_forward_second_port + 1))
done
dx_forward_third_port=$((dx_forward_second_port + 1))
while dx_port_in_use "$dx_forward_third_port" 2>/dev/null; do
    dx_forward_third_port=$((dx_forward_third_port + 1))
done
dx_forward_second_socket="$DX_FORWARD_SOCKET_TMP/dx-forward-dx-forward-test-$dx_forward_second_port.sock"
dx_forward_second_metadata="$dx_forward_second_socket.meta"
dx_forward_third_socket="$DX_FORWARD_SOCKET_TMP/dx-forward-dx-forward-test-$dx_forward_third_port.sock"
dx_forward_third_metadata="$dx_forward_third_socket.meta"
dx_forward_other_socket="$DX_FORWARD_SOCKET_TMP/dx-forward-dx-forward-test-2-$dx_forward_host_port.sock"
dx_forward_other_metadata="$dx_forward_other_socket.meta"

dx_forward_behavior "5173:$dx_forward_host_port" >/dev/null
DX_FORWARD_DEDUPED_LIST_OUT="$(dx_forward_behavior --list 2>&1 || true)"
if [ "$(printf '%s\n' "$DX_FORWARD_DEDUPED_LIST_OUT" | grep -c "Active http://127.0.0.1:$dx_forward_host_port")" -eq 1 ]; then
    test_pass "dx-forward lists an active socket and its metadata once"
else
    test_fail "dx-forward lists an active socket and its metadata once"
fi

dx_forward_behavior "5174:$dx_forward_second_port" >/dev/null
printf 'container=dx-forward-test\nhost_port=%s\nguest_port=5175\n' \
    "$dx_forward_third_port" > "$dx_forward_third_metadata"
touch "$dx_forward_other_socket"
printf 'container=dx-forward-test-2\nhost_port=%s\nguest_port=5173\n' \
    "$dx_forward_host_port" > "$dx_forward_other_metadata"

if DX_STUB_SSH_EXIT_FAIL_PORTS="$dx_forward_host_port" \
    dx_forward_behavior --stop-all > "$DX_FORWARD_BEHAVIOR_TMP/stop-all.out" 2>&1; then
    test_fail "dx-forward stop-all returns failure when one master cannot stop"
elif [ -e "$dx_forward_socket" ] \
    && [ -e "$dx_forward_metadata" ] \
    && [ ! -e "$dx_forward_second_socket" ] \
    && [ ! -e "$dx_forward_second_metadata" ] \
    && [ ! -e "$dx_forward_third_metadata" ] \
    && [ -e "$dx_forward_other_socket" ] \
    && [ -e "$dx_forward_other_metadata" ]; then
    test_pass "dx-forward stop-all continues cleanup and preserves failed and other-container state"
else
    test_fail "dx-forward stop-all continues cleanup and preserves failed and other-container state"
fi

DX_FORWARD_SCOPED_LIST_OUT="$(dx_forward_behavior --list 2>&1 || true)"
if ! printf '%s\n' "$DX_FORWARD_SCOPED_LIST_OUT" | grep -q "dx-forward-test-2"; then
    test_pass "dx-forward discovery excludes prefix-colliding container state"
else
    test_fail "dx-forward discovery excludes prefix-colliding container state"
fi

dx_forward_behavior --stop "$dx_forward_host_port" >/dev/null
rm -f "$dx_forward_other_socket" "$dx_forward_other_metadata"

# -----------------------------------------------------------------------------
# dx-reverse
# -----------------------------------------------------------------------------

DX_REVERSE="$BIN_DIR/dx-reverse"
assert_file_exists "$DX_REVERSE" "dx-reverse helper exists"
assert_file_contains "$DX_REVERSE" "source \"\$SCRIPT_DIR/dx-lib.sh\"" "dx-reverse uses shared script library"
assert_file_contains "$DX_REVERSE" "set -euo pipefail" "dx-reverse uses strict shell mode"
assert_file_contains "$DX_REVERSE" "ssh -f -N -M" "dx-reverse uses a background SSH master"
assert_file_contains "$DX_REVERSE" "ExitOnForwardFailure=yes" "dx-reverse fails when a remote forward cannot bind"
assert_file_contains "$DX_REVERSE" "127.0.0.1:\${guest_port}:127.0.0.1:\${host_port}" "dx-reverse binds guest reverse forwards to loopback"
assert_file_contains "$DX_REVERSE" "DX_CONTAINER_NAME" "dx-reverse namespaces sockets by configured container"
assert_file_contains "$DX_REVERSE" "DX_SSH_PORT" "dx-reverse uses configured SSH port"
assert_file_contains "$DX_REVERSE" "DX_SSH_KEY" "dx-reverse uses configured SSH key"
assert_file_contains "$DX_REVERSE" "DX_SSH_CONNECT_TIMEOUT" "dx-reverse uses configured SSH connect timeout"
assert_file_contains "$DX_REVERSE" "DX_REVERSE_WAIT_SSH" "dx-reverse allows tests to stub SSH readiness waiting"
assert_file_contains "$DX_REVERSE" "container_exists \"\$DX_CONTAINER_NAME\"" "dx-reverse verifies the configured container exists"
assert_file_contains "$DX_REVERSE" "container_is_running \"\$DX_CONTAINER_NAME\"" "dx-reverse verifies the configured container is running"
assert_file_contains "$DX_REVERSE" "validate_port" "dx-reverse validates port arguments"
assert_file_contains "$DX_REVERSE" "port < 1024" "dx-reverse rejects privileged guest ports"
assert_file_contains "$DX_REVERSE" "[[:space:]]--list)" "dx-reverse supports listing helper-managed reverse forwards"
assert_file_contains "$DX_REVERSE" "[[:space:]]--stop)" "dx-reverse supports stopping one reverse forward"
assert_file_contains "$DX_REVERSE" "[[:space:]]--stop-all)" "dx-reverse supports stopping all reverse forwards"
assert_file_contains "$DX_REVERSE" "ssh .* -O check" "dx-reverse checks existing control sockets"
assert_file_contains "$DX_REVERSE" "ssh .* -O exit" "dx-reverse stops reverse forwards through SSH control sockets"
assert_file_contains "$DX_REVERSE" "Reverse forwarded" "dx-reverse prints a guest access target"

DX_REVERSE_PARSE_OUTPUT="$(DX_REVERSE_TEST_MODE=parse "$DX_REVERSE" 5432 5432:15432 2>/dev/null || true)"
if [ "$DX_REVERSE_PARSE_OUTPUT" = $'5432:5432\n15432:5432' ]; then
    test_pass "dx-reverse parses bare and remapped port arguments"
else
    test_fail "dx-reverse parses bare and remapped port arguments"
fi

if DX_REVERSE_TEST_MODE=parse "$DX_REVERSE" foo >/dev/null 2>&1; then
    test_fail "dx-reverse rejects non-integer ports"
else
    test_pass "dx-reverse rejects non-integer ports"
fi

if DX_REVERSE_TEST_MODE=parse "$DX_REVERSE" 80 >/dev/null 2>&1; then
    test_fail "dx-reverse rejects privileged guest ports"
else
    test_pass "dx-reverse rejects privileged guest ports"
fi

if DX_REVERSE_TEST_MODE=parse "$DX_REVERSE" 70000 >/dev/null 2>&1; then
    test_fail "dx-reverse rejects out-of-range ports"
else
    test_pass "dx-reverse rejects out-of-range ports"
fi

DX_REVERSE_BEHAVIOR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dx-reverse-behavior.XXXXXX")"
DX_REVERSE_STUB_BIN="$DX_REVERSE_BEHAVIOR_TMP/bin"
DX_REVERSE_SOCKET_TMP="$DX_REVERSE_BEHAVIOR_TMP/tmp"
DX_REVERSE_SSH_LOG="$DX_REVERSE_BEHAVIOR_TMP/ssh.log"
DX_REVERSE_WAIT_LOG="$DX_REVERSE_BEHAVIOR_TMP/wait.log"
DX_REVERSE_KEY="$DX_REVERSE_BEHAVIOR_TMP/dx_key"
mkdir -p "$DX_REVERSE_STUB_BIN" "$DX_REVERSE_SOCKET_TMP"
touch "$DX_REVERSE_KEY"

cat > "$DX_REVERSE_STUB_BIN/container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
    "system status")
        exit 0
        ;;
    "list -a"|"list ")
        printf '%s\n' "${DX_CONTAINER_NAME:-dx-host}"
        exit 0
        ;;
esac

exit 0
EOF
chmod +x "$DX_REVERSE_STUB_BIN/container"

cat > "$DX_REVERSE_STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

socket=""
operation=""
reverse=""

selected_port() {
    local candidate="$1"
    local selected="${2:-}"

    case " $selected " in
        *" $candidate "*)
            return 0
            ;;
    esac
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -S)
            socket="$2"
            shift 2
            ;;
        -O)
            operation="$2"
            shift 2
            ;;
        -R)
            reverse="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

{
    printf 'operation=%s\n' "$operation"
    printf 'socket=%s\n' "$socket"
    printf 'reverse=%s\n' "$reverse"
} >> "${DX_REVERSE_SSH_LOG:?}"

case "$operation" in
    check)
        port="${socket%.sock}"
        port="${port##*-}"
        if selected_port "$port" "${DX_STUB_SSH_CHECK_FAIL_PORTS:-}"; then
            exit 1
        fi
        [ -n "$socket" ] && [ -e "$socket" ]
        exit $?
        ;;
    exit)
        port="${socket%.sock}"
        port="${port##*-}"
        if selected_port "$port" "${DX_STUB_SSH_EXIT_FAIL_PORTS:-}"; then
            if selected_port "$port" "${DX_STUB_SSH_EXIT_DISAPPEARS_PORTS:-}"; then
                rm -f "$socket"
            fi
            exit 1
        fi
        rm -f "$socket"
        exit 0
        ;;
esac

if [ -n "$socket" ]; then
    : > "$socket"
fi
exit 0
EOF
chmod +x "$DX_REVERSE_STUB_BIN/ssh"

cat > "$DX_REVERSE_STUB_BIN/dx-wait-ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'waited\n' >> "${DX_REVERSE_WAIT_LOG:?}"
EOF
chmod +x "$DX_REVERSE_STUB_BIN/dx-wait-ssh"

dx_reverse_behavior() {
    env \
        DX_CONTAINER_NAME=dx-reverse-test \
        DX_SSH_PORT=29998 \
        DX_SSH_KEY="$DX_REVERSE_KEY" \
        DX_SSH_CONNECT_TIMEOUT=1 \
        DX_REVERSE_WAIT_SSH="$DX_REVERSE_STUB_BIN/dx-wait-ssh" \
        DX_REVERSE_SSH_LOG="$DX_REVERSE_SSH_LOG" \
        DX_REVERSE_WAIT_LOG="$DX_REVERSE_WAIT_LOG" \
        TMPDIR="$DX_REVERSE_SOCKET_TMP" \
        PATH="$DX_REVERSE_STUB_BIN:$PATH" \
        "$DX_REVERSE" "$@"
}

dx_reverse_guest_port=31883
dx_reverse_host_port=5432
dx_reverse_socket="$DX_REVERSE_SOCKET_TMP/dx-reverse-dx-reverse-test-$dx_reverse_guest_port.sock"
dx_reverse_metadata="$dx_reverse_socket.meta"
rm -f "$DX_REVERSE_SSH_LOG" "$DX_REVERSE_WAIT_LOG"

DX_REVERSE_START_OUT="$(dx_reverse_behavior "$dx_reverse_host_port:$dx_reverse_guest_port" 2>&1 || true)"
if printf '%s\n' "$DX_REVERSE_START_OUT" | grep -q "Reverse forwarded dx-reverse-test 127.0.0.1:$dx_reverse_guest_port -> host 127.0.0.1:$dx_reverse_host_port" \
    && [ -e "$dx_reverse_socket" ] \
    && grep -qx "guest_port=$dx_reverse_guest_port" "$dx_reverse_metadata" \
    && grep -qx "host_port=$dx_reverse_host_port" "$dx_reverse_metadata" \
    && grep -qx "reverse=127.0.0.1:${dx_reverse_guest_port}:127.0.0.1:${dx_reverse_host_port}" "$DX_REVERSE_SSH_LOG" \
    && grep -qx "waited" "$DX_REVERSE_WAIT_LOG"; then
    test_pass "dx-reverse starts a loopback SSH reverse forward and writes metadata"
else
    test_fail "dx-reverse starts a loopback SSH reverse forward and writes metadata"
fi

DX_REVERSE_REPEAT_OUT="$(dx_reverse_behavior "$dx_reverse_host_port:$dx_reverse_guest_port" 2>&1 || true)"
if printf '%s\n' "$DX_REVERSE_REPEAT_OUT" | grep -q "Reverse forward already active dx-reverse-test 127.0.0.1:$dx_reverse_guest_port -> host 127.0.0.1:$dx_reverse_host_port"; then
    test_pass "dx-reverse treats an identical active reverse as idempotent"
else
    test_fail "dx-reverse treats an identical active reverse as idempotent"
fi

if dx_reverse_behavior "5433:$dx_reverse_guest_port" >/dev/null 2>&1; then
    test_fail "dx-reverse refuses to retarget an active guest port"
else
    test_pass "dx-reverse refuses to retarget an active guest port"
fi

DX_REVERSE_LIST_OUT="$(dx_reverse_behavior --list 2>&1 || true)"
if printf '%s\n' "$DX_REVERSE_LIST_OUT" | grep -q "Active dx-reverse-test 127.0.0.1:$dx_reverse_guest_port -> host 127.0.0.1:$dx_reverse_host_port"; then
    test_pass "dx-reverse lists active reverse forwards from control sockets and metadata"
else
    test_fail "dx-reverse lists active reverse forwards from control sockets and metadata"
fi

DX_REVERSE_STOP_OUT="$(dx_reverse_behavior --stop "$dx_reverse_guest_port" 2>&1 || true)"
if printf '%s\n' "$DX_REVERSE_STOP_OUT" | grep -q "Stopped reverse dx-reverse-test 127.0.0.1:$dx_reverse_guest_port" \
    && [ ! -e "$dx_reverse_socket" ] \
    && [ ! -e "$dx_reverse_metadata" ] \
    && grep -qx "operation=exit" "$DX_REVERSE_SSH_LOG"; then
    test_pass "dx-reverse stops an active reverse forward and removes socket metadata"
else
    test_fail "dx-reverse stops an active reverse forward and removes socket metadata"
fi

dx_reverse_behavior "$dx_reverse_host_port:$dx_reverse_guest_port" >/dev/null
if DX_STUB_SSH_EXIT_FAIL_PORTS="$dx_reverse_guest_port" \
    dx_reverse_behavior --stop "$dx_reverse_guest_port" > "$DX_REVERSE_BEHAVIOR_TMP/failed-stop.out" 2>&1; then
    test_fail "dx-reverse reports a failed exit while the SSH master remains active"
elif [ -e "$dx_reverse_socket" ] \
    && [ -e "$dx_reverse_metadata" ] \
    && grep -q "still active" "$DX_REVERSE_BEHAVIOR_TMP/failed-stop.out"; then
    test_pass "dx-reverse reports a failed exit while preserving active state"
else
    test_fail "dx-reverse reports a failed exit while preserving active state"
fi

if DX_STUB_SSH_EXIT_FAIL_PORTS="$dx_reverse_guest_port" \
    DX_STUB_SSH_EXIT_DISAPPEARS_PORTS="$dx_reverse_guest_port" \
    dx_reverse_behavior --stop "$dx_reverse_guest_port" > "$DX_REVERSE_BEHAVIOR_TMP/disappeared-stop.out" 2>&1 \
    && [ ! -e "$dx_reverse_socket" ] \
    && [ ! -e "$dx_reverse_metadata" ] \
    && grep -q "Stopped reverse dx-reverse-test 127.0.0.1:$dx_reverse_guest_port" "$DX_REVERSE_BEHAVIOR_TMP/disappeared-stop.out"; then
    test_pass "dx-reverse cleans state when exit fails after the master disappears"
else
    test_fail "dx-reverse cleans state when exit fails after the master disappears"
fi

printf 'container=dx-reverse-test\nguest_port=%s\nhost_port=%s\n' \
    "$dx_reverse_guest_port" "$dx_reverse_host_port" > "$dx_reverse_metadata"
if dx_reverse_behavior --stop "$dx_reverse_guest_port" > "$DX_REVERSE_BEHAVIOR_TMP/orphan-stop.out" 2>&1 \
    && [ ! -e "$dx_reverse_metadata" ] \
    && grep -q "Removed orphan dx-reverse metadata" "$DX_REVERSE_BEHAVIOR_TMP/orphan-stop.out"; then
    test_pass "dx-reverse explicit stop removes orphan metadata"
else
    test_fail "dx-reverse explicit stop removes orphan metadata"
fi

printf 'container=dx-reverse-test\nguest_port=%s\nhost_port=%s\n' \
    "$dx_reverse_guest_port" "$dx_reverse_host_port" > "$dx_reverse_metadata"
DX_REVERSE_ORPHAN_LIST_OUT="$(dx_reverse_behavior --list 2>&1 || true)"
if printf '%s\n' "$DX_REVERSE_ORPHAN_LIST_OUT" | grep -q "Orphan dx-reverse metadata for guest port $dx_reverse_guest_port" \
    && ! printf '%s\n' "$DX_REVERSE_ORPHAN_LIST_OUT" | grep -q "Active dx-reverse-test 127.0.0.1:$dx_reverse_guest_port"; then
    test_pass "dx-reverse lists orphan metadata without reporting it active"
else
    test_fail "dx-reverse lists orphan metadata without reporting it active"
fi
dx_reverse_behavior --stop "$dx_reverse_guest_port" >/dev/null

touch "$dx_reverse_socket"
printf 'container=dx-reverse-test\nguest_port=%s\nhost_port=%s\n' \
    "$dx_reverse_guest_port" "$dx_reverse_host_port" > "$dx_reverse_metadata"
DX_REVERSE_STALE_LIST_OUT="$(
    DX_STUB_SSH_CHECK_FAIL_PORTS="$dx_reverse_guest_port" dx_reverse_behavior --list 2>&1 || true
)"
if printf '%s\n' "$DX_REVERSE_STALE_LIST_OUT" | grep -q "Stale dx-reverse socket for guest port $dx_reverse_guest_port" \
    && DX_STUB_SSH_CHECK_FAIL_PORTS="$dx_reverse_guest_port" \
        dx_reverse_behavior --stop "$dx_reverse_guest_port" >/dev/null \
    && [ ! -e "$dx_reverse_socket" ] \
    && [ ! -e "$dx_reverse_metadata" ]; then
    test_pass "dx-reverse distinguishes and removes stale socket state"
else
    test_fail "dx-reverse distinguishes and removes stale socket state"
fi

dx_reverse_second_guest_port=$((dx_reverse_guest_port + 1))
dx_reverse_third_guest_port=$((dx_reverse_guest_port + 2))
dx_reverse_second_socket="$DX_REVERSE_SOCKET_TMP/dx-reverse-dx-reverse-test-$dx_reverse_second_guest_port.sock"
dx_reverse_second_metadata="$dx_reverse_second_socket.meta"
dx_reverse_third_socket="$DX_REVERSE_SOCKET_TMP/dx-reverse-dx-reverse-test-$dx_reverse_third_guest_port.sock"
dx_reverse_third_metadata="$dx_reverse_third_socket.meta"
dx_reverse_other_socket="$DX_REVERSE_SOCKET_TMP/dx-reverse-dx-reverse-test-2-$dx_reverse_guest_port.sock"
dx_reverse_other_metadata="$dx_reverse_other_socket.meta"

dx_reverse_behavior "$dx_reverse_host_port:$dx_reverse_guest_port" >/dev/null
DX_REVERSE_DEDUPED_LIST_OUT="$(dx_reverse_behavior --list 2>&1 || true)"
if [ "$(printf '%s\n' "$DX_REVERSE_DEDUPED_LIST_OUT" | grep -c "Active dx-reverse-test 127.0.0.1:$dx_reverse_guest_port")" -eq 1 ]; then
    test_pass "dx-reverse lists an active socket and its metadata once"
else
    test_fail "dx-reverse lists an active socket and its metadata once"
fi

dx_reverse_behavior "$((dx_reverse_host_port + 1)):$dx_reverse_second_guest_port" >/dev/null
printf 'container=dx-reverse-test\nguest_port=%s\nhost_port=%s\n' \
    "$dx_reverse_third_guest_port" "$((dx_reverse_host_port + 2))" > "$dx_reverse_third_metadata"
touch "$dx_reverse_other_socket"
printf 'container=dx-reverse-test-2\nguest_port=%s\nhost_port=%s\n' \
    "$dx_reverse_guest_port" "$dx_reverse_host_port" > "$dx_reverse_other_metadata"

if DX_STUB_SSH_EXIT_FAIL_PORTS="$dx_reverse_guest_port" \
    dx_reverse_behavior --stop-all > "$DX_REVERSE_BEHAVIOR_TMP/stop-all.out" 2>&1; then
    test_fail "dx-reverse stop-all returns failure when one master cannot stop"
elif [ -e "$dx_reverse_socket" ] \
    && [ -e "$dx_reverse_metadata" ] \
    && [ ! -e "$dx_reverse_second_socket" ] \
    && [ ! -e "$dx_reverse_second_metadata" ] \
    && [ ! -e "$dx_reverse_third_metadata" ] \
    && [ -e "$dx_reverse_other_socket" ] \
    && [ -e "$dx_reverse_other_metadata" ]; then
    test_pass "dx-reverse stop-all continues cleanup and preserves failed and other-container state"
else
    test_fail "dx-reverse stop-all continues cleanup and preserves failed and other-container state"
fi

DX_REVERSE_SCOPED_LIST_OUT="$(dx_reverse_behavior --list 2>&1 || true)"
if ! printf '%s\n' "$DX_REVERSE_SCOPED_LIST_OUT" | grep -q "dx-reverse-test-2"; then
    test_pass "dx-reverse discovery excludes prefix-colliding container state"
else
    test_fail "dx-reverse discovery excludes prefix-colliding container state"
fi

dx_reverse_behavior --stop "$dx_reverse_guest_port" >/dev/null
rm -f "$dx_reverse_other_socket" "$dx_reverse_other_metadata"

DX_REVERSE_LIVE_STUB="$DX_REVERSE_STUB_BIN/dx-reverse-live-stub"
DX_REVERSE_LIVE_LOG="$DX_REVERSE_BEHAVIOR_TMP/live-state.log"
DX_REVERSE_CALLER_SOCKET="$DX_REVERSE_SOCKET_TMP/dx-reverse-dx-reverse-test-49999.sock"

cat > "$DX_REVERSE_LIVE_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${TMPDIR:?}" in
    "${DX_REVERSE_ISOLATION_CALLER_TMP:?}"/*)
        ;;
    *)
        echo "dx-reverse live test used caller TMPDIR: $TMPDIR" >&2
        exit 1
        ;;
esac

printf '%s|%s\n' "$TMPDIR" "$*" >> "${DX_REVERSE_LIVE_LOG:?}"
socket="$TMPDIR/stub.sock"

case "${1:-}" in
    --list)
        [ -e "$socket" ]
        ;;
    --stop)
        if [ "${DX_REVERSE_LIVE_STOP_FAIL:-false}" = true ]; then
            exit 1
        fi
        rm -f "$socket" "$socket.meta"
        ;;
    *)
        touch "$socket" "$socket.meta"
        ;;
esac
EOF
chmod +x "$DX_REVERSE_LIVE_STUB"

dx_reverse_private_state_removed() {
    local state_dir
    local command

    while IFS='|' read -r state_dir command; do
        [ -n "$command" ] || continue
        [ ! -e "$state_dir" ] || return 1
    done < "$DX_REVERSE_LIVE_LOG"
}

touch "$DX_REVERSE_CALLER_SOCKET"
: > "$DX_REVERSE_LIVE_LOG"
if TMPDIR="$DX_REVERSE_SOCKET_TMP" \
    SKIP_INTEGRATION=true \
    DX_REVERSE_LIVE_TEST_MODE=state-isolation \
    DX_REVERSE_OVERRIDE="$DX_REVERSE_LIVE_STUB" \
    DX_REVERSE_ISOLATION_CALLER_TMP="$DX_REVERSE_SOCKET_TMP" \
    DX_REVERSE_LIVE_LOG="$DX_REVERSE_LIVE_LOG" \
    "$SCRIPT_DIR/test_section19_reverse_forward.sh" >/dev/null 2>&1 \
    && [ -e "$DX_REVERSE_CALLER_SOCKET" ] \
    && [ "$(wc -l < "$DX_REVERSE_LIVE_LOG" | tr -d ' ')" -eq 3 ] \
    && grep -q '|5432:15432$' "$DX_REVERSE_LIVE_LOG" \
    && grep -q '|--list$' "$DX_REVERSE_LIVE_LOG" \
    && grep -q '|--stop 15432$' "$DX_REVERSE_LIVE_LOG" \
    && dx_reverse_private_state_removed; then
    test_pass "dx-reverse live test isolates start, list, and cleanup state"
else
    test_fail "dx-reverse live test isolates start, list, and cleanup state"
fi

: > "$DX_REVERSE_LIVE_LOG"
if TMPDIR="$DX_REVERSE_SOCKET_TMP" \
    SKIP_INTEGRATION=true \
    DX_REVERSE_LIVE_TEST_MODE=state-isolation \
    DX_REVERSE_OVERRIDE="$DX_REVERSE_LIVE_STUB" \
    DX_REVERSE_ISOLATION_CALLER_TMP="$DX_REVERSE_SOCKET_TMP" \
    DX_REVERSE_LIVE_LOG="$DX_REVERSE_LIVE_LOG" \
    DX_REVERSE_LIVE_STOP_FAIL=true \
    "$SCRIPT_DIR/test_section19_reverse_forward.sh" >/dev/null 2>&1; then
    dx_reverse_failed_cleanup_status=0
else
    dx_reverse_failed_cleanup_status=$?
fi
dx_reverse_retained_state="$(awk -F'|' 'NR == 1 { print $1 }' "$DX_REVERSE_LIVE_LOG")"
if [ "$dx_reverse_failed_cleanup_status" -ne 0 ] \
    && [ -e "$DX_REVERSE_CALLER_SOCKET" ] \
    && [ -e "$dx_reverse_retained_state/stub.sock" ] \
    && [ -e "$dx_reverse_retained_state/stub.sock.meta" ]; then
    test_pass "dx-reverse live test retains private state when cleanup cannot stop its master"
else
    test_fail "dx-reverse live test retains private state when cleanup cannot stop its master"
fi
case "$dx_reverse_retained_state" in
    "$DX_REVERSE_SOCKET_TMP"/*)
        rm -rf "$dx_reverse_retained_state"
        ;;
esac
rm -f "$DX_REVERSE_CALLER_SOCKET"

# -----------------------------------------------------------------------------
# dx-put / dx-sync-bootstrap
# -----------------------------------------------------------------------------

DX_PUT="$BIN_DIR/dx-put"
if grep -q "if.*-z.*SOURCE\|if.*!\$.*1" "$DX_PUT"; then
    test_pass "dx-put handles missing arguments"
else
    test_fail "dx-put handles missing arguments"
fi

# -----------------------------------------------------------------------------
# dx-get / dx-put: directory copy-to-a-new-name and AppleDouble exclusion
#
# Both scripts tar basename(SOURCE) and used to always extract it verbatim,
# so a destination naming a NEW directory (cp -r's "copy AS" case) landed in
# the destination's PARENT instead of at the requested name. These tests
# drive the real host tar/extract pipeline end to end against a stub
# `container` and a fake guest filesystem rooted at a mktemp dir (never the
# real dx-host container), matching the stub convention used above for
# dx-start-container.
# -----------------------------------------------------------------------------

DX_GET="$BIN_DIR/dx-get"

DX_XFER_TMP="$(mktemp -d)"
DX_XFER_STUB_BIN="$DX_XFER_TMP/bin"
DX_XFER_GUEST_ROOT="$DX_XFER_TMP/guest"
DX_XFER_HOST="$DX_XFER_TMP/host"
mkdir -p "$DX_XFER_STUB_BIN" "$DX_XFER_GUEST_ROOT" "$DX_XFER_HOST"

cat > "$DX_XFER_STUB_BIN/container" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail

# Map a guest absolute path onto the fake guest filesystem rooted at
# DX_STUB_GUEST_ROOT (strip the leading '/').
strip_root() {
    printf '%s' "${DX_STUB_GUEST_ROOT:?}/${1#/}"
}

if [ "${1:-}" != "exec" ]; then
    echo "Unexpected container stub invocation (expected exec): $*" >&2
    exit 2
fi
shift

if [ "${1:-}" = "-i" ]; then
    shift
fi

# Container name -- unused for routing here, just consumed.
shift

cmd="${1:-}"
case "$cmd" in
    "[")
        flag="$2"
        path="$3"
        real="$(strip_root "$path")"
        case "$flag" in
            -e) [ -e "$real" ]; exit $? ;;
            -d) [ -d "$real" ]; exit $? ;;
            *) echo "Unexpected test-stub flag: $*" >&2; exit 2 ;;
        esac
        ;;
    tar)
        shift
        # Translate the -C directory argument onto the fake guest root and
        # run the real tar so archive streams actually move fixture data.
        new_args=()
        while [ $# -gt 0 ]; do
            if [ "$1" = "-C" ]; then
                new_args+=("-C" "$(strip_root "$2")")
                shift 2
            else
                new_args+=("$1")
                shift
            fi
        done
        exec tar "${new_args[@]}"
        ;;
    cat)
        shift
        real="$(strip_root "$1")"
        exec cat "$real"
        ;;
    chown)
        # No `dx` user exists on the host; the chown step is a no-op success.
        exit 0
        ;;
    bash)
        shift
        if [ "${1:-}" != "-c" ]; then
            echo "Unexpected bash invocation: $*" >&2
            exit 2
        fi
        script="$2"
        shift 2
        if [ "${1:-}" = "--" ]; then
            shift
        fi
        real="$(strip_root "${1:-}")"
        case "$script" in
            *'cat > "$1"'*)
                exec cat > "$real"
                ;;
            *mkdir*)
                # dx-put's "[ -d ] || (mkdir -p && chown)" helper: perform the
                # mkdir against the fake guest root; the chown half is a
                # deliberate no-op (no `dx` user on the host).
                [ -d "$real" ] || mkdir -p "$real"
                exit 0
                ;;
            *)
                echo "Unexpected bash -c script: $script" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "Unexpected container stub arguments: $*" >&2
        exit 2
        ;;
esac
STUBEOF
chmod +x "$DX_XFER_STUB_BIN/container"

dx_xfer_get() {
    env \
        PATH="$DX_XFER_STUB_BIN:$PATH" \
        DX_CONTAINER_NAME=dx-xfer-test \
        DX_STUB_GUEST_ROOT="$DX_XFER_GUEST_ROOT" \
        "$DX_GET" "$@"
}

dx_xfer_put() {
    env \
        PATH="$DX_XFER_STUB_BIN:$PATH" \
        DX_CONTAINER_NAME=dx-xfer-test \
        DX_STUB_GUEST_ROOT="$DX_XFER_GUEST_ROOT" \
        "$DX_PUT" "$@"
}

# --- dx-get fixtures: a fake /persist in the guest -------------------------
rm -rf "${DX_XFER_GUEST_ROOT:?}/persist"
mkdir -p "$DX_XFER_GUEST_ROOT/persist/subdir"
echo "one" > "$DX_XFER_GUEST_ROOT/persist/file1.txt"
echo "two" > "$DX_XFER_GUEST_ROOT/persist/subdir/file2.txt"

# dx-get dir -> new destination name (the headline bug: must be red first)
DX_XFER_DEST1="$DX_XFER_HOST/dest1"
mkdir -p "$DX_XFER_DEST1"
if dx_xfer_get /persist "$DX_XFER_DEST1/backup-x" >/dev/null 2>&1 \
    && [ -f "$DX_XFER_DEST1/backup-x/file1.txt" ] \
    && [ -f "$DX_XFER_DEST1/backup-x/subdir/file2.txt" ] \
    && [ ! -e "$DX_XFER_DEST1/persist" ]; then
    test_pass "dx-get copies a directory to a new destination name, not into its parent"
else
    test_fail "dx-get copies a directory to a new destination name, not into its parent"
fi

# dx-get dir -> existing destination directory (copy INTO it)
DX_XFER_DEST2="$DX_XFER_HOST/dest2"
mkdir -p "$DX_XFER_DEST2/into"
if dx_xfer_get /persist "$DX_XFER_DEST2/into" >/dev/null 2>&1 \
    && [ -f "$DX_XFER_DEST2/into/persist/file1.txt" ] \
    && [ -f "$DX_XFER_DEST2/into/persist/subdir/file2.txt" ]; then
    test_pass "dx-get copies a directory into an existing destination directory"
else
    test_fail "dx-get copies a directory into an existing destination directory"
fi

# dx-get dir -> trailing-slash destination (copy INTO it)
DX_XFER_DEST3="$DX_XFER_HOST/dest3"
if dx_xfer_get /persist "$DX_XFER_DEST3/slash/" >/dev/null 2>&1 \
    && [ -f "$DX_XFER_DEST3/slash/persist/file1.txt" ] \
    && [ -f "$DX_XFER_DEST3/slash/persist/subdir/file2.txt" ]; then
    test_pass "dx-get copies a directory into a trailing-slash destination"
else
    test_fail "dx-get copies a directory into a trailing-slash destination"
fi

# dx-get file -> new destination name
DX_XFER_DEST4="$DX_XFER_HOST/dest4"
mkdir -p "$DX_XFER_DEST4"
if dx_xfer_get /persist/file1.txt "$DX_XFER_DEST4/renamed.txt" >/dev/null 2>&1 \
    && [ -f "$DX_XFER_DEST4/renamed.txt" ] \
    && [ "$(cat "$DX_XFER_DEST4/renamed.txt")" = "one" ]; then
    test_pass "dx-get copies a file to an exact new destination path"
else
    test_fail "dx-get copies a file to an exact new destination path"
fi

# --- dx-put fixtures: a fake host source tree ------------------------------
mkdir -p "$DX_XFER_HOST/src/git"
echo "obj" > "$DX_XFER_HOST/src/git/objects.txt"

# dx-put dir -> new destination name with a differing basename
rm -rf "${DX_XFER_GUEST_ROOT:?}/persist"
mkdir -p "$DX_XFER_GUEST_ROOT/persist"
if dx_xfer_put "$DX_XFER_HOST/src/git" /persist/foo >/dev/null 2>&1 \
    && [ -f "$DX_XFER_GUEST_ROOT/persist/foo/objects.txt" ] \
    && [ ! -e "$DX_XFER_GUEST_ROOT/persist/git" ]; then
    test_pass "dx-put copies a directory to a new destination name, not by source basename"
else
    test_fail "dx-put copies a directory to a new destination name, not by source basename"
fi

# dx-put dir -> trailing-slash destination (copy INTO it)
rm -rf "${DX_XFER_GUEST_ROOT:?}/persist/inbox"
if dx_xfer_put "$DX_XFER_HOST/src/git" /persist/inbox/ >/dev/null 2>&1 \
    && [ -f "$DX_XFER_GUEST_ROOT/persist/inbox/git/objects.txt" ]; then
    test_pass "dx-put copies a directory into a trailing-slash destination"
else
    test_fail "dx-put copies a directory into a trailing-slash destination"
fi

# dx-put excludes macOS AppleDouble sidecar files (a real file, deterministic
# -- no need to make bsdtar actually generate one)
mkdir -p "$DX_XFER_HOST/src/withmeta"
echo "keep" > "$DX_XFER_HOST/src/withmeta/real.txt"
echo "meta" > "$DX_XFER_HOST/src/withmeta/._probe"
rm -rf "${DX_XFER_GUEST_ROOT:?}/persist/meta-dest"
if dx_xfer_put "$DX_XFER_HOST/src/withmeta" /persist/meta-dest >/dev/null 2>&1 \
    && [ -f "$DX_XFER_GUEST_ROOT/persist/meta-dest/real.txt" ] \
    && [ -z "$(find "$DX_XFER_GUEST_ROOT/persist/meta-dest" -name '._*')" ]; then
    test_pass "dx-put excludes macOS AppleDouble sidecar files from the guest"
else
    test_fail "dx-put excludes macOS AppleDouble sidecar files from the guest"
fi

rm -rf "$DX_XFER_TMP"

DX_SYNC_BOOTSTRAP="$BIN_DIR/dx-sync-bootstrap"
assert_file_exists "$DX_SYNC_BOOTSTRAP" "dx-sync-bootstrap exists"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_SOURCE" "dx-sync-bootstrap reads from configurable source"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_PATH" "dx-sync-bootstrap writes to configurable guest path"
assert_file_contains "$DX_SYNC_BOOTSTRAP" ".dx-bootstrap-ready" "dx-sync-bootstrap marks payload ready after copy"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "Unsafe DX_BOOTSTRAP_PATH" "dx-sync-bootstrap rejects unsafe guest paths"
assert_file_contains "$DX_SYNC_BOOTSTRAP" ".dx-bootstrap-waiting" "dx-sync-bootstrap waits for guest readiness marker"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "never became ready" "dx-sync-bootstrap exits with error if container entrypoint never becomes ready"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "container logs" "dx-sync-bootstrap points to container logs when entrypoint readiness times out"
assert_file_not_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_WAIT_FOR_GUEST" "dx-sync-bootstrap self-detects wait state without env-var coupling"
assert_file_not_contains "$DX_SYNC_BOOTSTRAP" "find \"\$dest\"" "dx-sync-bootstrap avoids nonessential guest dependencies"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "COPYFILE_DISABLE=1" "dx-sync-bootstrap suppresses macOS tar metadata"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "no-xattrs" "dx-sync-bootstrap omits tar xattrs"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "tar_create_args" "dx-sync-bootstrap probes optional tar flags"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "chmod -R a+rX" "dx-sync-bootstrap normalizes payload permissions"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "id -u dx" "dx-sync-bootstrap chowns payload when dx exists"

# -----------------------------------------------------------------------------
# dx-reclaim
# -----------------------------------------------------------------------------

DX_RECLAIM="$BIN_DIR/dx-reclaim"
assert_file_exists "$DX_RECLAIM" "dx-reclaim exists"
assert_file_contains "$DX_RECLAIM" "source \"\$SCRIPT_DIR/dx-lib.sh\"" "dx-reclaim uses shared script library"
assert_file_contains "$DX_RECLAIM" "container_is_running \"\$DX_CONTAINER_NAME\"" "dx-reclaim requires the configured container to be running"
assert_file_contains "$DX_RECLAIM" "DX_CONTAINER_VOLUME_DIR" "dx-reclaim uses configurable host volume directory"
assert_file_contains "$DX_RECLAIM" "DX_NIX_VOLUME" "dx-reclaim uses configured Nix volume name"
assert_file_contains "$DX_RECLAIM" "DX_PERSIST_VOLUME" "dx-reclaim uses configured persist volume name"
assert_file_contains "$DX_RECLAIM" "DX_NIX_MOUNT" "dx-reclaim trims the configured Nix mount"
assert_file_contains "$DX_RECLAIM" "trim_mount /persist" "dx-reclaim trims the fixed persist mount"
assert_file_not_contains "$DX_RECLAIM" "DX_PERSIST_PATH" "dx-reclaim does not consume DX_PERSIST_PATH"
assert_file_contains "$DX_RECLAIM" "nix-collect-garbage -d" "dx-reclaim deletes old Nix generations"
assert_file_contains "$DX_RECLAIM" "fstrim -v" "dx-reclaim returns free blocks to sparse host images"
assert_file_contains "$DX_RECLAIM" "du -sh" "dx-reclaim reports host sparse image usage"

# -----------------------------------------------------------------------------
# Layer model: every layer has a create/destroy pair, every create is idempotent
# -----------------------------------------------------------------------------

# Layer 1: keys
assert_file_exists "$BIN_DIR/dx-create-keys" "dx-create-keys exists"
assert_file_exists "$BIN_DIR/dx-destroy-keys" "dx-destroy-keys exists"
assert_file_contains "$BIN_DIR/dx-create-keys" "already exists; skipping" "dx-create-keys is idempotent"

# Layer 2: volumes
assert_file_exists "$BIN_DIR/dx-create-volumes" "dx-create-volumes exists"
assert_file_exists "$BIN_DIR/dx-destroy-volumes" "dx-destroy-volumes exists"
assert_file_contains "$BIN_DIR/dx-create-volumes" "container_ensure_volume" "dx-create-volumes uses idempotent volume ensure helper"
assert_file_contains "$BIN_DIR/dx-destroy-volumes" "Type \"destroy\" to confirm" "dx-destroy-volumes prompts for typed confirmation"
assert_file_contains "$BIN_DIR/dx-destroy-volumes" "force" "dx-destroy-volumes accepts --force to skip prompt"
assert_file_contains "$BIN_DIR/dx-destroy-volumes" "stdin is not a tty" "dx-destroy-volumes refuses non-interactive runs without --force"

# Layer 3: image
assert_file_exists "$BIN_DIR/dx-create-image" "dx-create-image exists"
assert_file_exists "$BIN_DIR/dx-destroy-image" "dx-destroy-image exists"
assert_file_contains "$BIN_DIR/dx-create-image" "container_image_exists" "dx-create-image is idempotent"
assert_file_contains "$BIN_DIR/dx-create-image" "already exists; skipping" "dx-create-image announces skip"

# Layer 4: container
assert_file_exists "$BIN_DIR/dx-create-container" "dx-create-container exists"
assert_file_exists "$BIN_DIR/dx-destroy-container" "dx-destroy-container exists"
assert_file_contains "$BIN_DIR/dx-create-container" "container_exists" "dx-create-container is idempotent"
assert_file_contains "$BIN_DIR/dx-create-container" "already exists; skipping" "dx-create-container announces skip"
assert_file_contains "$BIN_DIR/dx-create-container" "entrypoint sh" "dx-create-container sets a shell entrypoint"
assert_file_contains "$BIN_DIR/dx-create-container" "dx_bootstrap_launch_command" "dx-create-container uses shared bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_GIT_MOUNT_SOURCE" "dx-create-container supports explicit git mount source"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_GIT_MOUNT_TARGET" "dx-create-container mounts git source at configurable target"
assert_file_contains "$BIN_DIR/dx-create-container" "refusing to bind-mount.*dx-host" "dx-create-container refuses host mounts on dx-host"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_CONTAINER_MEMORY" "dx-create-container uses configurable memory"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_CONTAINER_CPUS" "dx-create-container uses configurable CPU count"

DX_MOUNT="$BIN_DIR/dx-mount"
assert_file_exists "$DX_MOUNT" "dx-mount side-container wrapper exists"
assert_file_contains "$DX_MOUNT" "dx_derived_name \"dx-mount-\"" "dx-mount derives typed side-container names"
assert_file_contains "$DX_MOUNT" "dx_require_non_reserved_container_name" "dx-mount refuses reserved dx-host name"
assert_file_contains "$DX_MOUNT" "DX_GIT_MOUNT_SOURCE" "dx-mount exports git mount source"
assert_file_contains "$DX_MOUNT" "DX_NIX_VOLUME=\"\$DX_CONTAINER_NAME-nix\"" "dx-mount defaults to private Nix volume"
assert_file_contains "$DX_MOUNT" "DX_PERSIST_VOLUME=\"\$DX_CONTAINER_NAME-persist\"" "dx-mount defaults to private persist volume"
assert_file_contains "$DX_MOUNT" "DX_BOOTSTRAP_VOLUME=\"\$DX_CONTAINER_NAME-bootstrap\"" "dx-mount defaults to private bootstrap volume"
assert_file_contains "$DX_MOUNT" "dx_derived_port" "dx-mount derives a non-default SSH port"
assert_file_contains "$DX_MOUNT" "print_env" "dx-mount has non-destructive environment inspection"
assert_file_contains "$DX_MOUNT" "dx-destroy-container" "dx-mount destroy removes the side container"
assert_file_contains "$DX_MOUNT" "dx-destroy-volumes.*--force" "dx-mount destroy removes private side volumes"
assert_file_contains "$DX_MOUNT" "dx-destroy-keys" "dx-mount destroy removes private side keypair"
assert_file_not_contains "$DX_MOUNT" "dx-destroy-image" "dx-mount destroy does not remove the shared image"

# Layer 5: runtime state
assert_file_exists "$BIN_DIR/dx-start-container" "dx-start-container exists"
assert_file_exists "$BIN_DIR/dx-stop-container" "dx-stop-container exists"
assert_file_contains "$BIN_DIR/dx-start-container" "already running; skipping" "dx-start-container is idempotent"
assert_file_contains "$BIN_DIR/dx-start-container" "dx-sync-bootstrap" "dx-start-container syncs bootstrap payload after ensuring runtime state"
assert_file_contains "$BIN_DIR/dx-stop-container" "container_stop_bounded" "dx-stop-container uses bounded stop helper"

# -----------------------------------------------------------------------------
# dx-start-container: host-site old-base guard
#
# Temporary coverage, removed together with bootstrap.sh's guard_old_base
# (see tests/test_section3_bootstrap.sh) once every machine has changed over.
# This machine has a real, live dx-host container -- these tests stub
# `container` on PATH so no real container is ever touched.
# -----------------------------------------------------------------------------

DX_START_CONTAINER="$BIN_DIR/dx-start-container"

DX_STARTC_TMP="$(mktemp -d)"
DX_STARTC_STUB_BIN="$DX_STARTC_TMP/bin"
mkdir -p "$DX_STARTC_STUB_BIN"

cat > "$DX_STARTC_STUB_BIN/container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list)
        if [ "${2:-}" = "-a" ]; then
            printf 'ID STATE\n'
            printf '%s stopped\n' "${DX_CONTAINER_NAME:-dx-host}"
        else
            printf 'ID STATE\n'
            printf '%s running\n' "${DX_CONTAINER_NAME:-dx-host}"
        fi
        ;;
    start)
        exit 0
        ;;
    exec)
        shift
        if [ "${1:-}" = "-i" ]; then
            # container exec -i <name> tar -xf - -C <path>: drain the payload
            # tarball dx-sync-bootstrap streams in; this stub does not need to
            # actually extract it.
            cat >/dev/null
            exit 0
        fi
        args="$*"
        case "$args" in
            # Only guard_old_base's own probe script embeds this literal
            # token (its OLD_BASE_ABSENT branch); every other `container exec
            # ... sh -c` call made by dx-sync-bootstrap should just succeed.
            *OLD_BASE_ABSENT*)
                if [ "${DX_STUB_GUARD_EXEC_FAIL:-false}" = "true" ]; then
                    exit 1
                fi
                printf '%s\n' "${DX_STUB_GUARD_RESPONSE:-OLD_BASE_ABSENT}"
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$DX_STARTC_STUB_BIN/container"

dx_startc_behavior() {
    local output_file="$1"
    shift
    env \
        PATH="$DX_STARTC_STUB_BIN:$PATH" \
        DX_CONTAINER_NAME=dx-startc-test \
        DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
        "$@" \
        "$DX_START_CONTAINER" >"$output_file" 2>&1
}

DX_STARTC_OUT="$(mktemp)"

if dx_startc_behavior "$DX_STARTC_OUT" DX_STUB_GUARD_RESPONSE=OLD_BASE_ABSENT; then
    test_pass "dx-start-container exits 0 when the guest guard reports OLD_BASE_ABSENT"
else
    test_fail "dx-start-container exits 0 when the guest guard reports OLD_BASE_ABSENT"
fi

set +e
dx_startc_behavior "$DX_STARTC_OUT" DX_STUB_GUARD_RESPONSE=OLD_BASE
DX_STARTC_OLDBASE_STATUS=$?
set -e
if [ "$DX_STARTC_OLDBASE_STATUS" -ne 0 ] \
    && grep -qi "changeover" "$DX_STARTC_OUT" \
    && grep -qi "flakes-base" "$DX_STARTC_OUT"; then
    test_pass "dx-start-container fails and names the changeover procedure when the guest guard reports OLD_BASE"
else
    test_fail "dx-start-container fails and names the changeover procedure when the guest guard reports OLD_BASE"
fi

set +e
dx_startc_behavior "$DX_STARTC_OUT" DX_STUB_GUARD_EXEC_FAIL=true
DX_STARTC_EXECFAIL_STATUS=$?
set -e
if [ "$DX_STARTC_EXECFAIL_STATUS" -ne 0 ] && grep -qi "could not verify" "$DX_STARTC_OUT"; then
    test_pass "dx-start-container fails closed when the guest guard's container exec fails"
else
    test_fail "dx-start-container fails closed when the guest guard's container exec fails"
fi

rm -f "$DX_STARTC_OUT"
rm -rf "$DX_STARTC_TMP"

# -----------------------------------------------------------------------------
# dx-destroy-container: bounded stop with force fallback
# -----------------------------------------------------------------------------

DX_DESTROY_CONTAINER="$BIN_DIR/dx-destroy-container"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_STOP_COMMAND_TIMEOUT" "dx-lib exposes stop command timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_stop_bounded" "dx-lib provides bounded container stop helper"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container kill" "dx-lib escalates stuck stops through container kill"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_runtime_pids" "dx-lib can find the host runtime process for one container"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_kill_runtime_process" "dx-lib has a targeted runtime-process fallback"
# Observed on Apple Container 0.12.0:
# container-runtime-linux start --root .../containers/dx-host --uuid dx-host
assert_file_contains "$BIN_DIR/dx-lib.sh" "index(\$0, \"--uuid \" name)" "dx-lib searches the observed runtime --uuid container-name signature"
assert_file_contains "$BIN_DIR/dx-lib.sh" "searched: ps -axo pid=,command=" "dx-lib logs the runtime-process search when no PID is found"
assert_file_contains "$DX_DESTROY_CONTAINER" "container_stop_bounded" "dx-destroy-container uses bounded stop helper"
assert_file_contains "$DX_DESTROY_CONTAINER" "container delete --force" "dx-destroy-container force-deletes when stop cannot complete"

# -----------------------------------------------------------------------------
# Wrappers: pure orchestration only
# -----------------------------------------------------------------------------

DX="$BIN_DIR/dx"
DX_DESTROY="$BIN_DIR/dx-destroy"
DX_RECREATE="$BIN_DIR/dx-recreate"
DX_FACTORY_RESET="$BIN_DIR/dx-factory-reset"

# dx calls every lifecycle script in order; idempotence makes it safe from any state
assert_file_contains "$DX" "dx-create-keys" "dx calls dx-create-keys"
assert_file_contains "$DX" "dx-create-image" "dx calls dx-create-image (builds image on first run)"
assert_file_contains "$DX" "dx-create-volumes" "dx calls dx-create-volumes"
assert_file_contains "$DX" "dx-create-container" "dx calls dx-create-container"
assert_file_contains "$DX" "dx-start-container" "dx calls dx-start-container"
assert_file_not_contains "$DX" "dx-sync-bootstrap" "dx delegates bootstrap sync to dx-start-container"
assert_file_contains "$DX" "dx-wait-ssh" "dx waits for SSH"
assert_file_contains "$DX" "dx-ssh" "dx connects via dx-ssh"
assert_file_not_contains "$DX" "container_is_running" "dx does not branch on container state itself"
assert_file_not_contains "$DX" "container_exists" "dx does not branch on container existence itself"

# dx-destroy umbrella
assert_file_exists "$DX_DESTROY" "dx-destroy umbrella exists"
assert_file_contains "$DX_DESTROY" "dx-destroy-container" "dx-destroy removes the container"
assert_file_contains "$DX_DESTROY" "dx-destroy-image" "dx-destroy removes the image"
assert_file_not_contains "$DX_DESTROY" "dx-destroy-volumes" "dx-destroy does NOT touch volumes"
assert_file_not_contains "$DX_DESTROY" "dx-destroy-keys" "dx-destroy does NOT touch keys"

# dx-recreate delegates to dx
assert_file_contains "$DX_RECREATE" 'exec "$SCRIPT_DIR/dx"' "dx-recreate delegates to the standard dx entrypoint"
assert_file_contains "$DX_RECREATE" "dx-destroy" "dx-recreate uses the dx-destroy umbrella"
assert_file_not_contains "$DX_RECREATE" "dx-destroy-volumes" "dx-recreate preserves volumes"
assert_file_not_contains "$DX_RECREATE" "dx-destroy-keys" "dx-recreate preserves keys"

# dx-factory-reset destroys every layer behind a confirmation prompt
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-container" "dx-factory-reset destroys the container"
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-image" "dx-factory-reset destroys the image"
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-volumes" "dx-factory-reset destroys the volumes"
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-keys" "dx-factory-reset destroys the keys"
assert_file_contains "$DX_FACTORY_RESET" 'dx-destroy-volumes" --force' "dx-factory-reset passes --force to dx-destroy-volumes to avoid double-prompting"
assert_file_contains "$DX_FACTORY_RESET" "factory-reset" "dx-factory-reset requires typed confirmation"

# The opt-in destructive regression must run unattended and prove the
# permissions that previously broke immediately after a factory reset.
DX_FACTORY_RESET_TEST="$BASE_DIR/tests/standalone_test_factory_reset.sh"
assert_file_contains "$DX_FACTORY_RESET_TEST" 'dx-factory-reset" --force' "standalone factory-reset test runs non-interactively"
assert_file_contains "$DX_FACTORY_RESET_TEST" "/persist/home/.dxe-write-probe" "standalone factory-reset test verifies persistent home writes"
assert_file_not_contains "$DX_FACTORY_RESET_TEST" "exit_with_code 1" "standalone factory-reset test cannot swallow explicit failures"

# -----------------------------------------------------------------------------
# standalone_test_factory_reset.sh: destructive-test safety guard (Finding 1)
#
# This script CREATES then irreversibly DESTROYS whatever DX_CONTAINER_NAME /
# DX_*_VOLUME / DX_SSH_KEY resolve to -- which default to the primary dx-host
# resources. It must refuse to run unless DX_TEST_DESTRUCTIVE=1 is set, and
# must still refuse if the resolved resources are the default/primary ones.
#
# Both scenarios below run a COPY of the script inside an isolated fake
# project tree (its own bin/dx-lib.sh, bin/dx, and bin/dx-factory-reset), and
# every DX_* override is cleared before invoking it. This way, even if the
# guard under test were broken, "Step 1" would only ever reach the fake
# stubs recorded in DX_GUARD_CALL_LOG -- never this machine's real, live
# dx-host, whose bin/dx and bin/dx-factory-reset live at real absolute paths
# that no amount of PATH stubbing alone could intercept.
# -----------------------------------------------------------------------------

DX_GUARD_TMP="$(mktemp -d)"
mkdir -p "$DX_GUARD_TMP/bin" "$DX_GUARD_TMP/tests"
cp "$BIN_DIR/dx-lib.sh" "$DX_GUARD_TMP/bin/dx-lib.sh"
cp "$DX_FACTORY_RESET_TEST" "$DX_GUARD_TMP/tests/standalone_test_factory_reset.sh"
chmod +x "$DX_GUARD_TMP/tests/standalone_test_factory_reset.sh"

DX_GUARD_CALL_LOG="$DX_GUARD_TMP/calls.log"
touch "$DX_GUARD_CALL_LOG"

cat > "$DX_GUARD_TMP/bin/dx" <<EOF
#!/bin/bash
echo "dx \$*" >> "$DX_GUARD_CALL_LOG"
exit 0
EOF
cat > "$DX_GUARD_TMP/bin/dx-factory-reset" <<EOF
#!/bin/bash
echo "dx-factory-reset \$*" >> "$DX_GUARD_CALL_LOG"
exit 0
EOF
chmod +x "$DX_GUARD_TMP/bin/dx" "$DX_GUARD_TMP/bin/dx-factory-reset"

dx_guard_run() {
    : > "$DX_GUARD_CALL_LOG"
    env \
        -u DX_TEST_DESTRUCTIVE -u DX_CONTAINER_NAME -u DX_NIX_VOLUME \
        -u DX_PERSIST_VOLUME -u DX_BOOTSTRAP_VOLUME -u DX_SSH_KEY -u DX_SSH_KEY_PUB \
        "$@" bash "$DX_GUARD_TMP/tests/standalone_test_factory_reset.sh"
}

# (a) No DX_TEST_DESTRUCTIVE opt-in: must skip cleanly (exit 0) and invoke
# neither dx nor dx-factory-reset.
set +e
dx_guard_run >"$DX_GUARD_TMP/no-optin.out" 2>&1
DX_GUARD_NO_OPTIN_STATUS=$?
set -e
if [ "$DX_GUARD_NO_OPTIN_STATUS" -eq 0 ] \
    && [ ! -s "$DX_GUARD_CALL_LOG" ] \
    && grep -qi "DX_TEST_DESTRUCTIVE=1" "$DX_GUARD_TMP/no-optin.out"; then
    test_pass "standalone factory-reset test skips without DX_TEST_DESTRUCTIVE and calls neither dx nor dx-factory-reset"
else
    test_fail "standalone factory-reset test skips without DX_TEST_DESTRUCTIVE and calls neither dx nor dx-factory-reset"
fi

# (b) DX_TEST_DESTRUCTIVE=1, but every DX_* resource is left at its default
# (dx-host / dx-nix / dx-persist / dx-bootstrap / default dx_key): must
# refuse (non-zero) and still invoke neither dx nor dx-factory-reset.
set +e
dx_guard_run DX_TEST_DESTRUCTIVE=1 >"$DX_GUARD_TMP/default-refuse.out" 2>&1
DX_GUARD_DEFAULT_STATUS=$?
set -e
if [ "$DX_GUARD_DEFAULT_STATUS" -ne 0 ] \
    && [ ! -s "$DX_GUARD_CALL_LOG" ] \
    && grep -qi "refusing" "$DX_GUARD_TMP/default-refuse.out"; then
    test_pass "standalone factory-reset test refuses default dx-host resources even with DX_TEST_DESTRUCTIVE=1"
else
    test_fail "standalone factory-reset test refuses default dx-host resources even with DX_TEST_DESTRUCTIVE=1"
fi

rm -rf "$DX_GUARD_TMP"

# Apple Container opens the published host port before guest sshd is ready.
# Test helpers must perform the same authenticated readiness check as dx.
assert_file_contains "$BASE_DIR/tests/test_helpers.sh" "dx-wait-ssh" "test readiness delegates to authenticated SSH waiting"
assert_file_not_contains "$BASE_DIR/tests/test_helpers.sh" "nc -z localhost" "test readiness does not mistake a published port for SSH"
if [ "$(grep -c "wait_for_ssh 180" "$BASE_DIR/tests/test_section11_validate_fresh.sh")" -ge 2 ]; then
    test_pass "stop/start persistence test waits for authenticated SSH"
else
    test_fail "stop/start persistence test waits for authenticated SSH"
fi

# -----------------------------------------------------------------------------
# Logging style: no Phase labels survive in the host scripts
# -----------------------------------------------------------------------------

for script in "$BIN_DIR"/dx*; do
    if [ -f "$script" ] && [ "$(basename "$script")" != "dx-lib.sh" ]; then
        if grep -qE "Phase [0-9]" "$script"; then
            test_fail "$(basename "$script") no longer prints Phase N labels"
        fi
    fi
done
test_pass "no host script prints Phase N labels"

# -----------------------------------------------------------------------------
# dx-wait-ssh
# -----------------------------------------------------------------------------

DX_WAIT_SSH="$BIN_DIR/dx-wait-ssh"
assert_file_contains "$DX_WAIT_SSH" "bash -lc 'true'" "dx-wait-ssh avoids nushell printing boolean true"
assert_file_contains "$DX_WAIT_SSH" "Waiting for guest SSH" "dx-wait-ssh announces what it is waiting for"
assert_file_contains "$DX_WAIT_SSH" "Guest is ready" "dx-wait-ssh announces readiness"

# -----------------------------------------------------------------------------
# dx-lib
# -----------------------------------------------------------------------------

assert_file_contains "$BIN_DIR/dx-lib.sh" "command -v container" "dx-lib checks for Apple Container installation"
assert_file_contains "$BIN_DIR/dx-lib.sh" "Apple 'container' command not found" "dx-lib install error names the missing command clearly"
assert_file_contains "$BIN_DIR/dx-lib.sh" "github.com/apple/container" "dx-lib install error points to the official install source"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_system_is_running" "dx-lib exposes container_system_is_running helper"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_system_ensure_started" "dx-lib exposes container_system_ensure_started helper"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container system status" "dx-lib queries container system status to detect started state"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container system start" "dx-lib starts the container system when it is not running"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_bootstrap_launch_command" "dx-lib owns bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-waiting" "dx-lib installs bootstrap wait marker"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-ready" "dx-lib waits for bootstrap ready marker"

assert_file_contains "$DX" "container_system_ensure_started" "dx ensures the container system is started before lifecycle steps"

print_summary
exit_with_code
