#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# Section 19: Reverse Forward Runtime
# Verifies dx-reverse exposes a macOS loopback service inside the running guest.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=../bin/lib/dx-host-util.sh
source "$BASE_DIR/bin/lib/dx-host-util.sh"

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

# --- WP3.4 (Fable A1): tunnel identity fails closed and is cached ---------
# Container-free: runs even under --skip-integration or with no Apple
# Container runtime at all. DX_RUNTIME=docker-ssh against a fake `ssh` that
# answers Docker daemon discovery (bin discovery + `docker info`/`version`)
# while a flag file says "up", and exits 255 (an unreachable host) once the
# flag is removed. The forward-8080 record is created the same way the real
# dx-forward CLI creates it -- the real dx_tunnel_* library functions, not a
# hand-rolled fixture file. Once "down" (and simulating a brand-new process:
# only WP3.4's own on-disk daemon-identity cache survives, never an
# in-memory DXE_RUNTIME_DOCKER_DAEMON_ID), dx_tunnel_list/--stop must still
# name and remove the SAME record, at the SAME socket path, without ever
# dialling ssh again (docs/reviews/2026-09-29-fable.md #A1).
dxe_s19_tunnel_result="$(mktemp "$CALLER_TMPDIR/dxe-s19-tunnel-identity-result.XXXXXX")"
(
    dxe_s19_home="$(mktemp -d "$CALLER_TMPDIR/dxe-s19-tunnel-home.XXXXXX")"
    dxe_s19_fake="$(mktemp -d "$CALLER_TMPDIR/dxe-s19-tunnel-fake.XXXXXX")"
    dxe_s19_flag="$dxe_s19_fake/up"
    dxe_s19_argv_log="$dxe_s19_fake/ssh-argv.log"
    : > "$dxe_s19_flag"
    : > "$dxe_s19_argv_log"

    # Appends (never truncates -- tests/lib/fake-tools.sh's own
    # fake_qnap_ssh_write uses `>`, which would only ever show the LAST
    # call and cannot prove "zero calls" across several), and reproduces
    # the docker-ssh management-plane transport's one-already-quoted-
    # command-string shape (dx_runtime_docker_ssh_raw): the last argument
    # is the whole remote command, evaluated in this fake's own process so
    # its own fake `docker` on the same PATH runs it.
    cat > "$dxe_s19_fake/ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$dxe_s19_argv_log"
[ -f "$dxe_s19_flag" ] || exit 255
dxe_s19_last=""
for dxe_s19_arg in "\$@"; do dxe_s19_last="\$dxe_s19_arg"; done
eval "\$dxe_s19_last"
EOF
    chmod 0755 "$dxe_s19_fake/ssh"

    cat > "$dxe_s19_fake/docker" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "s19fakedaemon|s19fake|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac
EOF
    chmod 0755 "$dxe_s19_fake/docker"

    PATH="$dxe_s19_fake:/usr/bin:/bin"
    unset XDG_STATE_HOME
    HOME="$dxe_s19_home"
    DX_RUNTIME=docker-ssh
    DX_REMOTE_HOST=s19-fake-host.invalid
    DX_CONTAINER_NAME=dx-s19-fake
    DX_NIX_STORAGE_MODE=direct-volume
    export PATH HOME DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_NIX_STORAGE_MODE
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID

    a_ok=1; b_ok=1; c_ok=1

    if source "$BASE_DIR/bin/dx-lib.sh" \
        && dx_tunnel_prepare_state \
        && socket_before="$(dx_tunnel_socket_path forward 8080)" \
        && metadata_before="$(dx_tunnel_metadata_path forward 8080)" \
        && dx_tunnel_metadata_write forward 8080 18080 \
        && [ -f "$metadata_before" ] \
        && [ -s "$dxe_s19_argv_log" ]; then

        # "down": a brand-new process would have neither
        # DXE_RUNTIME_DOCKER_BIN nor DXE_RUNTIME_DOCKER_DAEMON_ID in
        # memory -- only WP3.4's own on-disk cache -- so unset both here
        # to simulate exactly that, then remove the flag and clear the
        # argv log so assertion (c) below measures only the "down" phase.
        rm -f "$dxe_s19_flag"
        : > "$dxe_s19_argv_log"
        unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID

        list_out="$(dx_tunnel_list forward 2>&1)"
        if printf '%s\n' "$list_out" | grep -Fq -- "$socket_before"; then a_ok=0; fi

        stop_out="$(dx_tunnel_stop forward 8080 2>&1)"; stop_rc=$?
        if [ "$stop_rc" -eq 0 ] && [ ! -f "$metadata_before" ] \
            && ! printf '%s\n' "$stop_out" | grep -Fq "No dx-forward forward found"; then
            b_ok=0
        fi

        [ -s "$dxe_s19_argv_log" ] || c_ok=0
    fi

    printf 'a=%s\nb=%s\nc=%s\n' "$a_ok" "$b_ok" "$c_ok" > "$dxe_s19_tunnel_result"
    rm -rf "$dxe_s19_home" "$dxe_s19_fake" 2>/dev/null || true
)
# shellcheck disable=SC1090
source "$dxe_s19_tunnel_result"
rm -f "$dxe_s19_tunnel_result"
[ "${a:-1}" -eq 0 ] && test_pass "WP3.4: dx_tunnel_list names the same socket path once the host goes unreachable" \
    || test_fail "WP3.4: dx_tunnel_list names the same socket path once the host goes unreachable"
[ "${b:-1}" -eq 0 ] && test_pass "WP3.4: dx_tunnel_stop removes the record once the host goes unreachable" \
    || test_fail "WP3.4: dx_tunnel_stop removes the record once the host goes unreachable"
[ "${c:-1}" -eq 0 ] && test_pass "WP3.4: no ssh call is made while the host is unreachable" \
    || test_fail "WP3.4: no ssh call is made while the host is unreachable"

# --- WP8.3 step 5 (findings.md; docs/reviews/2026-09-29-fable.md A7):
# dx-forward/dx-reverse were merged into one dx_tunnel_cli in
# bin/lib/dx-tunnel.sh, with each entrypoint reduced to a two-line
# `<direction>_main` body. These cases were captured against the
# pre-merge, still-separate bin/dx-forward and bin/dx-reverse (each its
# own ~44-line argument parser) and must read identically post-merge:
# the exact --help usage text per direction, and a representative set of
# --stop/--list/unknown-option argument-handling error messages and exit
# codes. Container-free: every path here fails argument validation
# before ever touching a container, SSH, or the real tunnel state
# directory (isolated below via DX_TUNNEL_STATE_DIR regardless).
dxe_s19_cli_state="$(mktemp -d "$CALLER_TMPDIR/dxe-s19-cli-state.XXXXXX")"

dxe_s19_check() {
    local desc="$1" expected_out="$2" expected_rc="$3" out rc
    shift 3
    out="$(DX_TUNNEL_STATE_DIR="$dxe_s19_cli_state" "$@" 2>&1)"; rc=$?
    if [ "$out" = "$expected_out" ] && [ "$rc" -eq "$expected_rc" ]; then
        test_pass "$desc"
    else
        test_fail "$desc (rc=$rc, output: $out)"
    fi
}

dxe_s19_check "dx-forward --help prints the pinned usage text" \
"Usage:
  dx-forward <guest_port> [<guest_port> ...]
  dx-forward <guest_port>:<host_port> [<guest_port>:<host_port> ...]
  dx-forward --list | --stop <host_port> | --stop-all" 0 \
    "$BASE_DIR/bin/dx-forward" --help

dxe_s19_check "dx-reverse --help prints the pinned usage text" \
"Usage:
  dx-reverse <host_port> [<host_port> ...]
  dx-reverse <host_port>:<guest_port> [<host_port>:<guest_port> ...]
  dx-reverse --list | --stop <guest_port> | --stop-all" 0 \
    "$DX_REVERSE" --help

dxe_s19_check "dx-forward --stop with no port argument reports its usage" \
    "Error: Usage: dx-forward --stop <host_port>" 1 \
    "$BASE_DIR/bin/dx-forward" --stop

dxe_s19_check "dx-forward --stop with a non-numeric port is rejected" \
    "Error: host port 'notaport' is not an integer." 1 \
    "$BASE_DIR/bin/dx-forward" --stop notaport

dxe_s19_check "dx-forward --list refuses extra port arguments" \
    "Error: --list does not accept port arguments." 1 \
    "$BASE_DIR/bin/dx-forward" --list extra

dxe_s19_check "dx-forward rejects an unknown option" \
    "Error: Unknown option '--bogus'." 1 \
    "$BASE_DIR/bin/dx-forward" --bogus

dxe_s19_check "dx-reverse --stop with no port argument reports its usage" \
    "Error: Usage: dx-reverse --stop <guest_port>" 1 \
    "$DX_REVERSE" --stop

dxe_s19_check "dx-reverse --stop with a non-numeric port is rejected" \
    "Error: guest port 'notaport' is not an integer." 1 \
    "$DX_REVERSE" --stop notaport

dxe_s19_check "dx-reverse --list refuses extra port arguments" \
    "Error: --list does not accept port arguments." 1 \
    "$DX_REVERSE" --list extra

dxe_s19_check "dx-reverse rejects an unknown option" \
    "Error: Unknown option '--bogus'." 1 \
    "$DX_REVERSE" --bogus

# --- Direct-call battery: dx_tunnel_cli's own branches ---------------------
#
# Every case above already proves its string and exit code through the real
# bin/dx-forward/bin/dx-reverse entrypoints -- but each of those forks a
# brand-new bash process, and this sandbox's kcov does not attribute a
# forked script's own lines back to it (checked directly outside this
# suite: a trivial two-line script that always runs reports 0/2 lines
# covered when forked as a traced parent's child, and 2/2 when sourced and
# run in this same process), so the coverage gate never sees dx_tunnel_cli's
# own body execute no matter how many entrypoint-level cases exist above.
# These call it directly, in this already-traced process, for the branches
# above plus the ones WP8.3 did not yet have a case for: no arguments,
# --stop-all, a real --list call (not just its "extra arguments" refusal),
# and dx_tunnel_cli_collect's own duplicate-port and three-colon
# rejections. --list/--stop-all need no container or SSH at all
# (dx_tunnel_list/dx_tunnel_stop_all only read local tunnel state), so
# DX_TUNNEL_STATE_DIR alone keeps them container-free; a real port mapping
# does need dx_tunnel_require_prerequisites (SSH key, container up), which
# is exactly what SKIP_INTEGRATION means to skip, so that path stays
# untested here, same as above.
(
    source "$BASE_DIR/bin/dx-lib.sh"
    DX_TUNNEL_STATE_DIR="$dxe_s19_cli_state"
    DX_CONTAINER_NAME=dx-s19-direct
    export DX_TUNNEL_STATE_DIR DX_CONTAINER_NAME

    out="$(dx_tunnel_cli forward 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [ "$out" = "$(dx_tunnel_cli_usage forward)" ]; then
        test_pass "dx_tunnel_cli forward with no arguments prints its usage and fails (direct call)"
    else
        test_fail "dx_tunnel_cli forward with no arguments prints its usage and fails (direct call) (rc=$rc, out: $out)"
    fi

    out="$(dx_tunnel_cli forward --list 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "No dx-forward forwards found for dx-s19-direct." ]; then
        test_pass "dx_tunnel_cli forward --list reports no forwards against empty state (direct call)"
    else
        test_fail "dx_tunnel_cli forward --list reports no forwards against empty state (direct call) (rc=$rc, out: $out)"
    fi

    out="$(dx_tunnel_cli reverse --stop-all 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "No dx-reverse reverse forwards found for dx-s19-direct." ]; then
        test_pass "dx_tunnel_cli reverse --stop-all reports none found against empty state (direct call)"
    else
        test_fail "dx_tunnel_cli reverse --stop-all reports none found against empty state (direct call) (rc=$rc, out: $out)"
    fi

    out="$(dx_tunnel_cli forward --stop-all extra 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [ "$out" = "Error: --stop-all does not accept port arguments." ]; then
        test_pass "dx_tunnel_cli forward --stop-all refuses extra arguments (direct call)"
    else
        test_fail "dx_tunnel_cli forward --stop-all refuses extra arguments (direct call) (rc=$rc, out: $out)"
    fi

    # --stop <port>'s actual dispatch (dx_tunnel_stop), distinct from the
    # earlier --stop cases above (which only ever reach the usage/port
    # validation before it): like --list/--stop-all, dx_tunnel_stop only
    # reads local tunnel state, so this needs no container or SSH either.
    out="$(dx_tunnel_cli forward --stop 8080 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "No dx-forward forward found for host port 8080." ]; then
        test_pass "dx_tunnel_cli forward --stop <port> reports none found against empty state (direct call)"
    else
        test_fail "dx_tunnel_cli forward --stop <port> reports none found against empty state (direct call) (rc=$rc, out: $out)"
    fi

    out="$(dx_tunnel_cli forward 8080:9090:1000 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [ "$out" = "Error: Invalid forward '8080:9090:1000'. Use <guest_port> or <guest_port>:<host_port>." ]; then
        test_pass "dx_tunnel_cli forward refuses a mapping with more than one colon (direct call)"
    else
        test_fail "dx_tunnel_cli forward refuses a mapping with more than one colon (direct call) (rc=$rc, out: $out)"
    fi

    out="$(dx_tunnel_cli forward 8080:9090 8081:9090 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [ "$out" = "Error: Host port 9090 was requested more than once." ]; then
        test_pass "dx_tunnel_cli forward refuses the same host port requested twice (direct call)"
    else
        test_fail "dx_tunnel_cli forward refuses the same host port requested twice (direct call) (rc=$rc, out: $out)"
    fi

    out="$(dx_tunnel_cli bogus-direction 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
        test_pass "dx_tunnel_cli refuses an invalid direction (direct call)"
    else
        test_fail "dx_tunnel_cli refuses an invalid direction (direct call) (rc=$rc, out: $out)"
    fi

    # dx_tunnel_cli's own default ("a real port mapping") branch: bare-port
    # parsing (dx_tunnel_cli_parse_arg's own "no colon" arm), both
    # directions' dx_tunnel_cli_wait_ssh selections, and the
    # require_prerequisites + dx_tunnel_start dispatch loop -- all
    # deliberately left untested above (a real mapping needs a real
    # container/SSH, exactly what SKIP_INTEGRATION means to skip).
    # dx_tunnel_require_prerequisites and dx_tunnel_start are overridden
    # here (this whole battery runs in one already-isolated subshell; the
    # overrides never escape it) so this reaches dx_tunnel_cli's OWN lines
    # with no real network or container activity -- dx_tunnel_start's own
    # body is exercised for real elsewhere (this file's live round trip
    # below, when not skipped).
    dxe_s19_start_log="$dxe_s19_cli_state.start.log"
    dx_tunnel_require_prerequisites() { :; }
    dx_tunnel_start() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$dxe_s19_start_log"; }

    : > "$dxe_s19_start_log"
    out="$(dx_tunnel_cli forward 8080 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "$dxe_s19_start_log")" = "forward 8080 8080" ]; then
        test_pass "dx_tunnel_cli forward with a bare port (no colon) maps it to itself and reaches dx_tunnel_start (direct call)"
    else
        test_fail "dx_tunnel_cli forward with a bare port (no colon) maps it to itself and reaches dx_tunnel_start (direct call) (rc=$rc, log: $(cat "$dxe_s19_start_log" 2>/dev/null))"
    fi

    : > "$dxe_s19_start_log"
    out="$(dx_tunnel_cli reverse 8080:9090 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "$dxe_s19_start_log")" = "reverse 9090 8080" ]; then
        test_pass "dx_tunnel_cli reverse with a colon mapping reaches dx_tunnel_start with both ports resolved (direct call)"
    else
        test_fail "dx_tunnel_cli reverse with a colon mapping reaches dx_tunnel_start with both ports resolved (direct call) (rc=$rc, log: $(cat "$dxe_s19_start_log" 2>/dev/null))"
    fi

    rm -f "$dxe_s19_start_log"
)

rm -rf "$dxe_s19_cli_state"

if ! live_tail_enabled; then
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
    test_fail "SSH not reachable on the guest (SSH port $DX_SSH_PORT)"
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
if printf '%s\n' "$reverse_list" | stdin_matches "Active $DX_CONTAINER_NAME 127.0.0.1:$guest_port -> host 127.0.0.1:$host_port"; then
    test_pass "dx-reverse --list shows the live reverse forward"
else
    test_fail "dx-reverse --list shows the live reverse forward"
fi

guest_fetch="$(guest_bash "curl -fsS --max-time 5 http://127.0.0.1:$guest_port/reverse-test.txt" 2>&1 || true)"
if printf '%s\n' "$guest_fetch" | stdin_matches "$marker"; then
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
