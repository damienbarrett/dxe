#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "Shared DX and QNAP connection entrypoint"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-qx.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
unset DX_PROFILES_DIR
export XDG_CONFIG_HOME="$fixture/config"
mkdir -p "$fixture/bin/lib" "$fixture/tests/profiles"
cp "$BASE_DIR/bin/dx" "$BASE_DIR/bin/qx" "$BASE_DIR/bin/dx-profile" "$fixture/bin/"
cp "$BASE_DIR/bin/lib/dx-config.sh" "$fixture/bin/lib/"
printf '%s\n' 'DX_CONTAINER_NAME=dx-qnap-contract' > "$fixture/tests/profiles/qnap-canary.env"
export QX_TEST_BASE_DIR="$BASE_DIR"
cat > "$fixture/bin/dx-lib.sh" <<'LIB'
source "$QX_TEST_BASE_DIR/bin/lib/dx-host-util.sh"
source "$QX_TEST_BASE_DIR/bin/lib/dx-container.sh"
DX_SYSTEM_WAIT_TIMEOUT=2
DX_SLEEP=qx_fake_sleep
qx_fake_sleep() { printf 'sleep:%s\n' "$1" >> "$QX_TEST_LOG"; }
service_started=false
service_polls=0
dx_runtime_system_running() {
    printf '%s\n' system-status >> "$QX_TEST_LOG"
    [ "${QX_TEST_SERVICE_STATE:-running}" != running ] || return 0
    [ "$service_started" = true ] || return 1
    service_polls=$((service_polls + 1))
    [ "$service_polls" -gt "${QX_TEST_SERVICE_DELAY:-1}" ]
}
dx_runtime_system_start() {
    printf '%s\n' system-start >> "$QX_TEST_LOG"
    if [ "${DX_RUNTIME:-apple}" = docker-ssh ]; then
        dx_runtime_docker_system_start
        return $?
    fi
    [ "${QX_TEST_START_STATUS:-0}" -eq 0 ] || return "$QX_TEST_START_STATUS"
    service_started=true
}
dx_require_container_cli() {
    printf '%s\n' available >> "$QX_TEST_LOG"
    return "${QX_TEST_AVAILABLE_STATUS:-0}"
}
container_is_running() {
    printf 'running:%s\n' "$1" >> "$QX_TEST_LOG"
    [ "${QX_TEST_STATE:-running}" = running ]
}
container_owned() {
    printf 'owned:%s:%s\n' "$1" "$2" >> "$QX_TEST_LOG"
    return "${QX_TEST_OWNED_STATUS:-0}"
}
dx_lifecycle_lock_acquire() { printf '%s\n' lock >> "$QX_TEST_LOG"; return "${QX_TEST_LOCK_STATUS:-0}"; }
dx_lifecycle_lock_release() { printf '%s\n' unlock >> "$QX_TEST_LOG"; }
LIB
for entrypoint in dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh dx-ssh; do
    cat > "$fixture/bin/$entrypoint" <<'COMMAND'
#!/bin/bash
set -euo pipefail
printf '%s\n' "${0##*/}" >> "$QX_TEST_LOG"
if [ "${0##*/}" = dx-ssh ]; then
    printf '<%s>\n' "$@" > "$QX_TEST_ARGS"
    exit "${QX_TEST_COMMAND_STATUS:-0}"
fi
exit "${QX_TEST_LIFECYCLE_STATUS:-0}"
COMMAND
    chmod +x "$fixture/bin/$entrypoint"
done
export QX_TEST_LOG="$fixture/operations" QX_TEST_ARGS="$fixture/arguments"

run_qx() {
    : > "$QX_TEST_LOG"
    rm -f "$QX_TEST_ARGS"
    qx_status=0
    "$fixture/bin/${QX_TEST_ENTRYPOINT:-qx}" "$@" || qx_status=$?
}
expect_log() {
    printf '%s\n' "$@" > "$fixture/expected-log"
    cmp -s "$fixture/expected-log" "$QX_TEST_LOG"
}

# Commands must reach SSH with their original argument boundaries, and
# reconnecting a running guest must never invoke a lifecycle operation.
run_qx 'printf "%s\n" "two words"' '' '-argument'
printf '<%s>\n' 'printf "%s\n" "two words"' '' '-argument' > "$fixture/expected-args"
if [ "$qx_status" -eq 0 ] \
    && expect_log available system-status running:dx-qnap-contract lock owned:dx-qnap-contract:connect unlock dx-ssh \
    && cmp -s "$fixture/expected-args" "$QX_TEST_ARGS"; then
    test_pass "running canary connects directly with the profile and preserves argument boundaries"
else
    test_fail "running canary connects directly with the profile and preserves argument boundaries"
fi
run_qx
if [ "$qx_status" -eq 0 ] && expect_log available system-status running:dx-qnap-contract lock owned:dx-qnap-contract:connect unlock dx-ssh; then
    test_pass "interactive qx reaches the existing SSH/tmux entrypoint"
else
    test_fail "interactive qx reaches the existing SSH/tmux entrypoint"
fi
for state in stopped absent; do
    QX_TEST_STATE="$state" run_qx 'uname -a'
    printf '<%s>\n' 'uname -a' > "$fixture/expected-args"
    if [ "$qx_status" -eq 0 ] && expect_log available system-status running:dx-qnap-contract lock system-status dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh unlock dx-ssh \
        && cmp -s "$fixture/expected-args" "$QX_TEST_ARGS"; then
        test_pass "$state canary uses full bring-up and forwards the command"
    else
        test_fail "$state canary uses full bring-up and forwards the command"
    fi
done
QX_TEST_AVAILABLE_STATUS=42 run_qx 'uname -a'
if [ "$qx_status" -eq 42 ] && expect_log available && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "unreachable runtime fails before SSH or lifecycle dispatch"
else
    test_fail "unreachable runtime fails before SSH or lifecycle dispatch"
fi
QX_TEST_OWNED_STATUS=17 run_qx 'uname -a'
if [ "$qx_status" -eq 17 ] && expect_log available system-status running:dx-qnap-contract lock owned:dx-qnap-contract:connect unlock \
    && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "foreign same-named container is refused before SSH"
else
    test_fail "foreign same-named container is refused before SSH"
fi
QX_TEST_LOCK_STATUS=1 run_qx 'uname -a'
if [ "$qx_status" -ne 0 ] && expect_log available system-status running:dx-qnap-contract lock \
    && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "a held lifecycle lock refuses a reconnect before the ownership check, SSH or any lifecycle child"
else
    test_fail "a held lifecycle lock refuses a reconnect before the ownership check, SSH or any lifecycle child (status $qx_status)"
fi
QX_TEST_COMMAND_STATUS=23 run_qx 'uname -a'
if [ "$qx_status" -eq 23 ] && expect_log available system-status running:dx-qnap-contract lock owned:dx-qnap-contract:connect unlock dx-ssh; then
    test_pass "SSH failure propagates without trying a lifecycle update"
else
    test_fail "SSH failure propagates without trying a lifecycle update"
fi

# The ordinary entrypoint exercises the same path under a different container.
DX_CONTAINER_NAME=dx-local-contract QX_TEST_ENTRYPOINT=dx run_qx 'uname -a'
if [ "$qx_status" -eq 0 ] && expect_log available system-status running:dx-local-contract lock owned:dx-local-contract:connect unlock dx-ssh; then
    test_pass "dx connects directly under its selected container"
else
    test_fail "dx connects directly under its selected container"
fi
DX_CONTAINER_NAME=dx-local-contract QX_TEST_ENTRYPOINT=dx QX_TEST_STATE=stopped run_qx 'uname -a'
if [ "$qx_status" -eq 0 ] && expect_log available system-status running:dx-local-contract lock system-status dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh unlock dx-ssh; then
    test_pass "dx retains the full bring-up sequence when stopped"
else
    test_fail "dx retains the full bring-up sequence when stopped"
fi
QX_TEST_STATE=stopped QX_TEST_LIFECYCLE_STATUS=19 run_qx 'uname -a'
if [ "$qx_status" -eq 19 ] && expect_log available system-status running:dx-qnap-contract lock system-status dx-create-keys unlock && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "bring-up failure releases the lock and never connects"
else
    test_fail "bring-up failure releases the lock and never connects"
fi

# The real ensure_started helper must wait before any guest-state query,
# while the orchestration holds one lock through startup and releases it
# before SSH. The injected sleep makes delayed readiness deterministic.
for state in running stopped; do
    DX_CONTAINER_NAME=dx-local-contract QX_TEST_ENTRYPOINT=dx QX_TEST_STATE="$state" QX_TEST_SERVICE_STATE=stopped run_qx 'uname -a'
    if [ "$state" = running ]; then
        expect_log available system-status lock system-status system-start system-status sleep:1 system-status running:dx-local-contract owned:dx-local-contract:connect unlock dx-ssh && result=0 || result=1
    else
        expect_log available system-status lock system-status system-start system-status sleep:1 system-status running:dx-local-contract dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh unlock dx-ssh && result=0 || result=1
    fi
    if [ "$qx_status" -eq 0 ] && [ "$result" -eq 0 ]; then
        test_pass "stopped service starts once, waits, and releases its lock before connecting to $state guest"
    else
        test_fail "stopped service starts once, waits, and releases its lock before connecting to $state guest"
    fi
done
QX_TEST_ENTRYPOINT=dx QX_TEST_SERVICE_STATE=stopped QX_TEST_START_STATUS=27 run_qx
if [ "$qx_status" -eq 27 ] && expect_log available system-status lock system-status system-start unlock && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "service-start failure releases its lock without querying the guest"
else
    test_fail "service-start failure releases its lock without querying the guest"
fi
QX_TEST_ENTRYPOINT=dx QX_TEST_SERVICE_STATE=stopped QX_TEST_SERVICE_DELAY=99 run_qx
if [ "$qx_status" -eq 1 ] && expect_log available system-status lock system-status system-start system-status sleep:1 system-status sleep:1 system-status unlock && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "service-readiness timeout releases its lock without connecting or bringing up the guest"
else
    test_fail "service-readiness timeout releases its lock without connecting or bringing up the guest"
fi
DX_RUNTIME=docker-ssh DX_NIX_STORAGE_MODE=direct-volume DX_REMOTE_HOST=qnap QX_TEST_SERVICE_STATE=stopped run_qx
if [ "$qx_status" -eq 1 ] && expect_log available system-status lock system-status system-start unlock && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "QNAP adapter still refuses automatic Container Station service startup"
else
    test_fail "QNAP adapter still refuses automatic Container Station service startup"
fi

# User profiles live outside the checkout, and explicit profile directories
# remain authoritative for isolated test runs and automation.
mkdir -p "$XDG_CONFIG_HOME/dxe/profiles" "$fixture/override" "$fixture/home/.config/dxe/profiles"
printf '%s\n' 'DX_CONTAINER_NAME=dx-user-contract' > "$XDG_CONFIG_HOME/dxe/profiles/qnap-canary.env"
run_qx 'uname -a'
if [ "$qx_status" -eq 0 ] && expect_log available system-status running:dx-user-contract lock owned:dx-user-contract:connect unlock dx-ssh; then
    test_pass "qx prefers external XDG user config over the bundled profile"
else
    test_fail "qx prefers external XDG user config over the bundled profile"
fi
printf '%s\n' 'DX_CONTAINER_NAME=dx-override-contract' > "$fixture/override/qnap-canary.env"
DX_PROFILES_DIR="$fixture/override" run_qx
if [ "$qx_status" -eq 0 ] && expect_log available system-status running:dx-override-contract lock owned:dx-override-contract:connect unlock dx-ssh; then
    test_pass "explicit DX_PROFILES_DIR overrides user and bundled profiles"
else
    test_fail "explicit DX_PROFILES_DIR overrides user and bundled profiles"
fi
DX_PROFILES_DIR="$fixture/missing" run_qx 2> "$fixture/missing-error"
if [ "$qx_status" -eq 1 ] && [ ! -s "$QX_TEST_LOG" ] && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "missing explicit profile never falls back to another target"
else
    test_fail "missing explicit profile never falls back to another target"
fi
printf '%s\n' 'DX_CONTAINER_NAME=dx-home-contract' > "$fixture/home/.config/dxe/profiles/qnap-canary.env"
HOME="$fixture/home" XDG_CONFIG_HOME= run_qx
if [ "$qx_status" -eq 0 ] && expect_log available system-status running:dx-home-contract lock owned:dx-home-contract:connect unlock dx-ssh; then
    test_pass "qx uses HOME/.config when XDG_CONFIG_HOME is empty"
else
    test_fail "qx uses HOME/.config when XDG_CONFIG_HOME is empty"
fi
printf '%s\n' 'DX_CONTAINER_NAME=$(false)' > "$XDG_CONFIG_HOME/dxe/profiles/qnap-canary.env"
run_qx 2> "$fixture/invalid-error"
if [ "$qx_status" -ne 0 ] && [ ! -s "$QX_TEST_LOG" ] && [ ! -e "$QX_TEST_ARGS" ]; then
    test_pass "invalid user profile fails without falling back to bundled configuration"
else
    test_fail "invalid user profile fails without falling back to bundled configuration"
fi

print_summary
exit_with_code
