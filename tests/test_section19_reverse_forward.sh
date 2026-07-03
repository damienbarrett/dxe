#!/bin/bash
# Section 19: Reverse Forward Runtime
# Verifies dx-reverse exposes a macOS loopback service inside the running guest.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

DX_REVERSE="${DX_REVERSE_OVERRIDE:-$BASE_DIR/bin/dx-reverse}"
CALLER_TMPDIR="${TMPDIR:-/tmp}"
CALLER_TMPDIR="${CALLER_TMPDIR%/}"
tmp_dir=""
reverse_state_dir=""
server_pid=""
forward_created=false
guest_port=""

create_private_state() {
    tmp_dir="$(mktemp -d "$CALLER_TMPDIR/XXXXXX")"
    reverse_state_dir="$tmp_dir"
}

dx_reverse() {
    TMPDIR="$reverse_state_dir" "$DX_REVERSE" "$@"
}

cleanup() {
    local state_safe_to_remove=true

    if [ "$forward_created" = true ] && [ -n "$guest_port" ] && [ -d "$reverse_state_dir" ]; then
        if dx_reverse --stop "$guest_port" >/dev/null 2>&1; then
            forward_created=false
        else
            state_safe_to_remove=false
            echo "Error: reverse-forward test cleanup could not stop guest port $guest_port." >&2
            echo "Private control state retained at $reverse_state_dir." >&2
        fi
    fi
    if [ -n "$server_pid" ]; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" >/dev/null 2>&1 || true
    fi
    if [ -n "$tmp_dir" ] && [ "$state_safe_to_remove" = true ]; then
        rm -rf "$tmp_dir"
    fi

    if [ "$state_safe_to_remove" = false ]; then
        trap - EXIT
        exit 1
    fi
}

if [ "${DX_REVERSE_LIVE_TEST_MODE:-}" = "state-isolation" ]; then
    guest_port=15432
    create_private_state
    trap cleanup EXIT

    if ! dx_reverse 5432:15432 >/dev/null 2>&1; then
        exit 1
    fi
    forward_created=true
    dx_reverse --list >/dev/null 2>&1
    exit $?
fi

test_section "Section 19: Reverse Forward Runtime"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "dx-reverse live round trip skipped by --skip-integration"
    print_summary
    exit_with_code
fi

assert_file_exists "$DX_REVERSE" "dx-reverse helper exists"

if ! command -v python3 >/dev/null 2>&1; then
    test_skip "host python3 is not available for temporary HTTP server"
    print_summary
    exit_with_code
fi

if ! command -v curl >/dev/null 2>&1; then
    test_skip "host curl is not available for temporary HTTP probe"
    print_summary
    exit_with_code
fi

if ! requires_container; then
    print_summary
    exit_with_code
fi

if ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
    print_summary
    exit_with_code
fi

if ! guest_bash "command -v curl >/dev/null" >/dev/null 2>&1; then
    test_skip "guest curl is not available for reverse-forward HTTP probe"
    print_summary
    exit_with_code
fi

port_in_use() {
    local port="$1"
    dx_port_in_use "$port" >/dev/null 2>&1
}

find_host_port() {
    local port="$1"
    local attempts=0

    while port_in_use "$port" && [ "$attempts" -lt 100 ]; do
        port=$((port + 1))
        attempts=$((attempts + 1))
    done

    printf '%s\n' "$port"
}

guest_port_in_use() {
    local port="$1"
    guest_bash "(: </dev/tcp/127.0.0.1/$port) >/dev/null 2>&1" >/dev/null 2>&1
}

find_guest_port() {
    local port="$1"
    local attempts=0

    while guest_port_in_use "$port" && [ "$attempts" -lt 100 ]; do
        port=$((port + 1))
        attempts=$((attempts + 1))
    done

    if guest_port_in_use "$port"; then
        return 1
    fi

    printf '%s\n' "$port"
}

host_port="$(find_host_port "$((39200 + ($$ % 500)))")"
if ! guest_port="$(find_guest_port "$((49200 + ($$ % 500)))")"; then
    test_skip "no free guest loopback port found for reverse-forward test"
    print_summary
    exit_with_code
fi
marker="dx-reverse-live-test-$$"
create_private_state
trap cleanup EXIT

printf '%s\n' "$marker" > "$tmp_dir/reverse-test.txt"
python3 -m http.server "$host_port" --bind 127.0.0.1 --directory "$tmp_dir" > "$tmp_dir/http.log" 2>&1 &
server_pid=$!

for _ in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:$host_port/reverse-test.txt" >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done

if ! curl -fsS "http://127.0.0.1:$host_port/reverse-test.txt" >/dev/null 2>&1; then
    test_skip "host loopback HTTP server could not start on 127.0.0.1:$host_port"
    print_summary
    exit_with_code
fi
test_pass "host loopback HTTP fixture is reachable"

if dx_reverse "$host_port:$guest_port" >/dev/null 2>&1; then
    forward_created=true
    test_pass "dx-reverse starts a live guest-to-host reverse forward"
else
    test_fail "dx-reverse starts a live guest-to-host reverse forward"
    print_summary
    exit_with_code
fi

reverse_list="$(dx_reverse --list 2>&1 || true)"
if printf '%s\n' "$reverse_list" | grep -q "Active $DX_CONTAINER_NAME 127.0.0.1:$guest_port -> host 127.0.0.1:$host_port"; then
    test_pass "dx-reverse --list shows the live reverse forward"
else
    test_fail "dx-reverse --list shows the live reverse forward"
fi

guest_fetch="$(guest_bash "curl -fsS --max-time 5 http://127.0.0.1:$guest_port/reverse-test.txt" 2>&1 || true)"
if printf '%s\n' "$guest_fetch" | grep -q "$marker"; then
    test_pass "guest reaches the host HTTP fixture through dx-reverse"
else
    test_fail "guest reaches the host HTTP fixture through dx-reverse"
fi

if dx_reverse --stop "$guest_port" >/dev/null 2>&1; then
    forward_created=false
    test_pass "dx-reverse stops the live reverse forward"
else
    test_fail "dx-reverse stops the live reverse forward"
fi

if guest_bash "curl -fsS --max-time 2 http://127.0.0.1:$guest_port/reverse-test.txt" >/dev/null 2>&1; then
    test_fail "guest cannot reach the host fixture after dx-reverse --stop"
else
    test_pass "guest cannot reach the host fixture after dx-reverse --stop"
fi

print_summary
exit_with_code
