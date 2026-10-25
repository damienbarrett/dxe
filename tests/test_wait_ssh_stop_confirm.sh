#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP-WAITSSH (plans/do/wait-ssh/spec.md): bin/dx-wait-ssh asks
# dx_container_wait_should_abort after every failed SSH probe, and that used
# to stop the wait on ONE "stopped" reading (the container exists but is not
# running). Under load Apple's `container list --quiet` can answer empty once
# while `container list -a --quiet` still lists the guest, and docker-ssh's
# running inspect can fail once on an ssh hiccup: one such reading killed a
# healthy boot (2026-08-01, a dx-recreate during a kcov build). A stop is now
# reported only on the third consecutive stopped reading.
#
# Interface contract:
#
#  1. The count. bin/lib/dx-container.sh keeps the number of consecutive
#     stopped readings of the current wait in the plain shell variable
#     DXE_WAIT_STOPPED_READINGS, in the shell that runs the wait, never
#     exported (the DXE_LIFECYCLE_LOCK_HELD pattern). Unset reads as 0, also
#     under `set -u`.
#  2. dx_container_wait_begin (new, bin/lib/dx-container.sh): no arguments,
#     no output, status 0; sets DXE_WAIT_STOPPED_READINGS=0 whatever it held
#     or the environment brought (D-4). It runs in the waiting shell itself,
#     never inside $(...), or the reset dies with the subshell.
#  3. bin/dx-wait-ssh: wait_ssh_main calls dx_container_wait_begin once per
#     wait, after RESTART_BASELINE is read and before the first probe. That
#     call is the file's only change (D-5): one line, stated in the
#     unscoped-ceiling comment of tests/coverage/ratchet.env, or folded into
#     an existing line.
#  4. dx_container_wait_should_abort <baseline>: name, argument and return
#     convention unchanged -- 0 when it printed why the wait must stop, 1 to
#     keep waiting. Each call takes ONE reading (D-1): container_exists
#     "$DX_CONTAINER_NAME" once and, only when that succeeded,
#     container_is_running "$DX_CONTAINER_NAME" once (the dx-container.sh
#     wrappers, as today). Exists succeeded and running failed -- for any
#     reason, a failed running query included -- is a stopped reading: the
#     count goes up by one. Any other reading (running; exists failed, for
#     any reason) sets the count to 0.
#       a. When the count reaches 3 (a constant: no setting, nothing from the
#          environment changes it) it prints the unchanged D-3 text on stderr
#          and returns 0, with no restart-count query (the stop is checked
#          before the crash loop, as today):
#            Error: Container <name> stopped before SSH became responsive.
#            Last 80 container log lines:
#            <dx_container_print_logs 80>
#       b. Otherwise (stopped readings one and two, and every not-stopped
#          reading) it prints nothing about the stop and runs today's
#          crash-loop check unchanged: one dx_runtime_container_restart_count
#          query; a rise of 2 or more over <baseline> prints the crash-loop
#          text (its last 20 log lines and the dx-recreate advice) and
#          returns 0; otherwise 1.
#     No sleep (DX_SLEEP, sleep, dx_wait_until), no retry and no other
#     runtime call inside it.
#  5. Everything else in bin/dx-wait-ssh is as at 15eab2b: per failed probe
#     the order probe -> should_abort -> timeout check -> tick -> "." -> one
#     "${DX_SLEEP:-sleep}" call; the timeout report; every message.
#
# How the cases drive it (existing seams only). Section A calls the library
# in this shell (the lines kcov counts). Sections B and C run a copy of
# bin/dx-wait-ssh beside a stub dx-lib.sh (tests/test_wait_ssh_crashloop.sh's
# pattern): the stubbed dx_ssh_probe_login_shell numbers the probes in
# $WS_STATE/probes and can set SECONDS so the timeout falls on a chosen
# probe; DX_SLEEP names a recording function. In B the readings are stubbed
# per probe. In C only the probe, dx_require_container_cli and the sleep are
# stubbed: container_exists, container_is_running, the restart count and the
# logs go through the real Apple and docker-ssh adapters to a fake
# `container` / `docker` CLI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"
test_section "dx-wait-ssh stops on a stopped container only after three consecutive stopped readings"

fixture="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir fixture "${TMPDIR:-/tmp}/dxe-wait-stop.XXXXXX"
trap 'rm -rf "$fixture"' EXIT
export HOME="$fixture/home" DX_PROFILES_DIR="$fixture/profiles"
mkdir -p "$HOME" "$DX_PROFILES_DIR" "$fixture/tmp" "$fixture/lib" "$fixture/state"
unset XDG_STATE_HOME DXE_WAIT_STOPPED_READINGS DX_SSH_PROGRESS_INTERVAL_FIRST

# shellcheck source=../bin/lib/dx-config.sh
source "$BASE_DIR/bin/lib/dx-config.sh"
# shellcheck source=../bin/lib/dx-host-util.sh
source "$BASE_DIR/bin/lib/dx-host-util.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
# shellcheck source=../bin/lib/dx-container.sh
source "$BASE_DIR/bin/lib/dx-container.sh"

# The texts every abort must print, unchanged (D-3); the fakes' log tail is
# always these two lines.
stop_text() {
    printf 'Error: Container dx-wait stopped before SSH became responsive.\nLast 80 container log lines:\n  guest log line 1\n  guest log line 2\n'
}
crash_text() { # crash_text FROM TO
    printf 'Error: Container dx-wait is crash-looping: its restart count rose from %s to %s while waiting for SSH.\nLast 20 container log lines:\n  guest log line 1\n  guest log line 2\nCheck the bootstrap error in those lines and the profile it was created from; after fixing the cause, run dx-recreate (or dx-destroy-container then dx).\n' "$1" "$2"
}
timeout_text() {
    printf 'Error: Timed out after 3600s waiting for guest SSH service to become responsive.\nLast 80 container log lines:\n  guest log line 1\n  guest log line 2\n'
}

# --- A. the library, in this shell -------------------------------------------
# Each case runs in a subshell with the readings stubbed below the library:
# LIB_READING is run (exists, running), stop (exists, not running), gone
# (exists fails) or err (the exists query itself fails, status 2). Every call
# below the library, sleeps included, lands in $LIB_CALLS.
lib_seq=0
lib_fail() {
    printf '%s\n' "$*" >> "$LIB_DIR/why"
    exit 1
}
lib_setup() {
    LIB_DIR="$1" LIB_CALLS="$1/calls" LIB_ERR="$1/err"
    : > "$LIB_CALLS"
    : > "$LIB_ERR"
    DX_CONTAINER_NAME=dx-wait LIB_BASELINE=0 LIB_RESTARTS=0 LIB_READING=run
    unset DX_SLEEP
    container_exists() {
        printf 'exists\n' >> "$LIB_CALLS"
        case "$LIB_READING" in
            gone) return 1 ;;
            err) return 2 ;;
        esac
        return 0
    }
    container_is_running() {
        printf 'running\n' >> "$LIB_CALLS"
        [ "$LIB_READING" = run ]
    }
    dx_runtime_container_restart_count() {
        printf 'restart\n' >> "$LIB_CALLS"
        printf '%s\n' "$LIB_RESTARTS"
    }
    dx_runtime_logs() {
        printf 'logs %s\n' "$*" >> "$LIB_CALLS"
        printf 'guest log line 1\nguest log line 2\n'
    }
    sleep() { printf 'sleep %s\n' "$*" >> "$LIB_CALLS"; }
    dx_wait_until() {
        printf 'dx_wait_until %s\n' "$*" >> "$LIB_CALLS"
        return 1
    }
}
lib_need_begin() {
    type dx_container_wait_begin >/dev/null 2>&1 || lib_fail "dx_container_wait_begin is not defined"
}
# lib_read READING -- one dx_container_wait_should_abort call in this shell
# (never in $(...), so the count carries over); its status lands in lib_rc.
lib_read() {
    LIB_READING="$1"
    lib_rc=0
    dx_container_wait_should_abort "$LIB_BASELINE" 2>> "$LIB_ERR" || lib_rc=$?
}
lib_rc_is() {
    [ "$lib_rc" = "$1" ] || lib_fail "$2: dx_container_wait_should_abort returned $lib_rc, expected $1"
}
lib_count_is() {
    [ "${DXE_WAIT_STOPPED_READINGS-unset}" = "$1" ] \
        || lib_fail "$2: DXE_WAIT_STOPPED_READINGS is ${DXE_WAIT_STOPPED_READINGS-unset}, expected $1"
}
lib_err_is() {
    [ "$(cat "$LIB_ERR")" = "$1" ] || lib_fail "$2: stderr was [$(tr '\n' '|' < "$LIB_ERR")]"
}
lib_calls_are() {
    [ "$(cat "$LIB_CALLS")" = "$(printf '%s\n' "$@")" ] \
        || lib_fail "calls were [$(tr '\n' '|' < "$LIB_CALLS")], expected [$(printf '%s|' "$@")]"
}
lib_case() { # lib_case DESCRIPTION BODY_FUNCTION
    local dir
    lib_seq=$((lib_seq + 1))
    dir="$fixture/lib/$lib_seq"
    mkdir -p "$dir"
    : > "$dir/why"
    if ( lib_setup "$dir"; "$2"; : > "$dir/done" ) > "$dir/out" 2>&1 && [ -f "$dir/done" ] && [ ! -s "$dir/why" ]; then
        test_pass "$1"
    else
        test_fail "$1 ($(tr '\n' ' ' < "$dir/why")- output: [$(tr '\n' '|' < "$dir/out")])"
    fi
}

lib_body_third_stop() {
    local attrs
    lib_need_begin
    dx_container_wait_begin
    lib_count_is 0 "after dx_container_wait_begin"
    lib_read stop
    lib_rc_is 1 "the first stopped reading"
    lib_count_is 1 "the first stopped reading"
    lib_read stop
    lib_rc_is 1 "the second stopped reading"
    lib_count_is 2 "the second stopped reading"
    lib_err_is "" "two stopped readings"
    lib_read stop
    lib_rc_is 0 "the third stopped reading"
    lib_err_is "$(stop_text)" "the third stopped reading"
    lib_calls_are exists running restart exists running restart exists running "logs -n 80 dx-wait"
    attrs="$(declare -p DXE_WAIT_STOPPED_READINGS 2>/dev/null || true)"
    attrs="${attrs#declare -}"
    attrs="${attrs%% *}"
    case "$attrs" in
        *x*) lib_fail "DXE_WAIT_STOPPED_READINGS is exported" ;;
    esac
}
lib_case "A1 (D-2): two stopped readings keep the wait going silently, one reading and one restart-count query each; the third stops it with the D-3 text and the 80-line tail, no restart-count query; the count is DXE_WAIT_STOPPED_READINGS, not exported" lib_body_third_stop

lib_body_resets() {
    local reading
    lib_need_begin
    dx_container_wait_begin
    for reading in stop stop run stop stop gone stop stop err stop stop; do
        lib_read "$reading"
        lib_rc_is 1 "reading $reading"
        case "$reading" in
            stop) : ;;
            *) lib_count_is 0 "after a not-stopped reading ($reading)" ;;
        esac
    done
    lib_err_is "" "pairs of stopped readings broken by running, absent and failed-query readings"
    lib_read stop
    lib_rc_is 0 "the third consecutive stopped reading after the resets"
    lib_err_is "$(stop_text)" "the third consecutive stopped reading after the resets"
}
lib_case "A2 (D-1, D-2): a running reading, an absent container and a failed exists query each reset the count to 0; only three consecutive stopped readings stop the wait" lib_body_resets

lib_body_begin_resets() {
    lib_need_begin
    dx_container_wait_begin
    lib_read stop
    lib_read stop
    lib_rc_is 1 "the first wait's second stopped reading"
    dx_container_wait_begin
    lib_count_is 0 "dx_container_wait_begin after two stopped readings"
    lib_read stop
    lib_rc_is 1 "the second wait's first stopped reading"
    lib_read stop
    lib_rc_is 1 "the second wait's second stopped reading"
    lib_err_is "" "a second wait after two stopped readings"
    lib_read stop
    lib_rc_is 0 "the second wait's third stopped reading"
    : > "$LIB_ERR"
    DXE_WAIT_STOPPED_READINGS=2
    export DXE_WAIT_STOPPED_READINGS
    dx_container_wait_begin
    lib_count_is 0 "dx_container_wait_begin with a leftover 2 in the environment"
    lib_read stop
    lib_rc_is 1 "a fresh wait's first stopped reading despite the leftover"
    lib_read stop
    lib_rc_is 1 "a fresh wait's second stopped reading despite the leftover"
    lib_err_is "" "a fresh wait with a leftover count"
}
lib_case "A3 (D-4): dx_container_wait_begin starts every wait at 0, after an earlier wait in the same shell and over a leftover exported count" lib_body_begin_resets

lib_body_unset() {
    unset DXE_WAIT_STOPPED_READINGS
    set -u
    lib_read stop
    lib_rc_is 1 "a first stopped reading with the count unset"
    lib_count_is 1 "a first stopped reading with the count unset"
    lib_read stop
    lib_rc_is 1 "a second stopped reading"
    lib_read stop
    lib_rc_is 0 "a third stopped reading"
    lib_err_is "$(stop_text)" "three stopped readings before any dx_container_wait_begin"
}
lib_case "A4: an unset count reads as 0 under set -u (no dx_container_wait_begin yet): the third stopped reading stops, not the first" lib_body_unset

lib_body_crash() {
    lib_need_begin
    dx_container_wait_begin
    LIB_BASELINE=4 LIB_RESTARTS=6
    lib_read stop
    lib_rc_is 0 "a first stopped reading with the restart count up by 2"
    lib_err_is "$(crash_text 4 6)" "a crash loop on the first stopped reading"
    lib_calls_are exists running restart "logs -n 20 dx-wait"
    : > "$LIB_ERR"
    : > "$LIB_CALLS"
    dx_container_wait_begin
    LIB_RESTARTS=4
    lib_read stop
    lib_rc_is 1 "a first stopped reading with a flat restart count"
    LIB_RESTARTS=7
    lib_read stop
    lib_rc_is 0 "a second stopped reading with the restart count up by 3"
    lib_err_is "$(crash_text 4 7)" "a crash loop on the second stopped reading"
    lib_calls_are exists running restart exists running restart "logs -n 20 dx-wait"
}
lib_case "A5 (D-3): the crash-loop check still runs on the first and second stopped readings and aborts there with the crash-loop text, not the stop text" lib_body_crash

# --- B. bin/dx-wait-ssh, readings stubbed per probe ---------------------------
test_section "dx-wait-ssh with the readings stubbed per probe"
mkdir -p "$fixture/stub-bin" "$fixture/adapter-bin"
cp "$BASE_DIR/bin/dx-wait-ssh" "$fixture/stub-bin/"
cp "$BASE_DIR/bin/dx-wait-ssh" "$fixture/adapter-bin/"
# The part of the stub dx-lib.sh both copies share: the real libraries, the
# probe counter, the recording sleep.
ws_common_lib() {
    printf 'WS_LIB_ROOT=%q\n' "$BASE_DIR"
    cat <<'LIB'
source "$WS_LIB_ROOT/bin/lib/dx-config.sh"
source "$WS_LIB_ROOT/bin/lib/dx-host-util.sh"
source "$WS_LIB_ROOT/bin/lib/dx-container.sh"
dx_require_container_cli() { :; }
ws_log() { printf '%s\n' "$*" >> "$WS_STATE/calls"; }
ws_probe_number() { cat "$WS_STATE/probes" 2>/dev/null || echo 0; }
# ws_token N TOKEN... -- the Nth token (from 1); past the end, the last one.
ws_token() {
    local i="$1" tok last=""
    shift
    for tok in "$@"; do
        last="$tok"
        i=$((i - 1))
        [ "$i" -gt 0 ] || break
    done
    printf '%s\n' "$last"
}
# The probe counter drives the scenario: failed probe N is call N. WS_JUMP_AT
# moves SECONDS (this runs in the waiting shell) so the timeout check falls
# on that probe.
dx_ssh_probe_login_shell() {
    local n
    n=$(( $(ws_probe_number) + 1 ))
    echo "$n" > "$WS_STATE/probes"
    ws_log "probe $n"
    if [ "$n" = "${WS_JUMP_AT:-0}" ]; then SECONDS=$WS_JUMP_TO; fi
    [ "$n" -ge "${WS_SUCCEED_AT:-99999}" ]
}
ws_sleep() { ws_log "sleep $*"; }
LIB
}
{
    ws_common_lib
    cat <<'LIB'
# WS_READINGS: the reading on failed probe N is token N -- run, stop, gone
# (exists fails) or err (the exists query fails, status 2).
ws_reading() { ws_token "$(ws_probe_number)" ${WS_READINGS:-run}; }
container_exists() {
    ws_log exists
    case "$(ws_reading)" in
        gone) return 1 ;;
        err) return 2 ;;
    esac
    return 0
}
container_is_running() { ws_log running; [ "$(ws_reading)" = run ]; }
# WS_RESTARTS: token 1 is the baseline, token N+1 the count on failed probe N.
dx_runtime_container_restart_count() { ws_log restart; ws_token "$(( $(ws_probe_number) + 1 ))" ${WS_RESTARTS:-0}; }
dx_runtime_logs() { ws_log "logs $*"; printf 'guest log line 1\nguest log line 2\n'; }
LIB
} > "$fixture/stub-bin/dx-lib.sh"
ws_common_lib > "$fixture/adapter-bin/dx-lib.sh"

export DX_CONTAINER_NAME=dx-wait DX_SSH_WAIT_TIMEOUT=3600 DX_SSH_POLL_INTERVAL=1 DX_SSH_PROGRESS_INTERVAL=100000 DX_SLEEP=ws_sleep
# Fail-closed tools (no real container/docker/ssh) plus a recording `sleep`:
# a sleep inside the check would show up in the call log.
stub_tools="$(fake_tool_dir_create "$fixture")" || exit 1
fake_tool_write "$stub_tools" sleep 'printf "external sleep %s\n" "$*" >> "$WS_STATE/calls"'

ws_seq=0
# ws_run BIN_DIR TOOLS_DIR [NAME=VALUE...] -- one wait in a fresh state
# directory: status in ws_rc; out, err, calls (stub log), cli (fake CLI argv).
ws_run() {
    local bin="$1" tools="$2"
    shift 2
    ws_seq=$((ws_seq + 1))
    WS_STATE="$fixture/state/$ws_seq"
    mkdir -p "$WS_STATE"
    : > "$WS_STATE/calls"
    : > "$WS_STATE/cli"
    export WS_STATE
    ws_rc=0
    env "$@" PATH="$tools:/usr/bin:/bin" "$bin/dx-wait-ssh" > "$WS_STATE/out" 2> "$WS_STATE/err" || ws_rc=$?
}
stub_run() { ws_run "$fixture/stub-bin" "$stub_tools" "$@"; }
ws_file() { cat "$WS_STATE/$1" 2>/dev/null || true; }

ws_header() {
    printf 'Waiting for guest SSH to become responsive...\n'
    printf 'Bootstrap wait limit: 3600s (approximately 60 minutes). A fresh factory-reset bootstrap can take several minutes.\n'
}
ws_dots() {
    local i=0
    while [ "$i" -lt "$1" ]; do
        printf '.'
        i=$((i + 1))
    done
}
ws_ready_out() { ws_header; ws_dots "$1"; printf '\nGuest is ready.\n'; } # $1 failed probes
ws_stopped_out() { ws_header; ws_dots "$1"; } # $1 failed probes before the one that ends the wait

# ws_calls KIND... -- the stubbed wait's call log: the baseline restart-count
# query, then per probe
#   f  failed, a reading with both queries: exists, running, restart, sleep 1
#   g  failed, the exists query failed:     exists, restart, sleep 1
#   x  failed, the third stopped reading:   exists, running, logs -n 80
#   c  failed, a crash loop on a stopped reading: exists, running, restart, logs -n 20
#   t  failed, the timeout falls on it:     exists, running, restart, exists, logs -n 80
#   s  the probe that succeeds
ws_calls() {
    local n=0 kind
    printf 'restart\n'
    for kind in "$@"; do
        n=$((n + 1))
        printf 'probe %s\n' "$n"
        case "$kind" in
            f) printf 'exists\nrunning\nrestart\nsleep 1\n' ;;
            g) printf 'exists\nrestart\nsleep 1\n' ;;
            x) printf 'exists\nrunning\nlogs -n 80 dx-wait\n' ;;
            c) printf 'exists\nrunning\nrestart\nlogs -n 20 dx-wait\n' ;;
            t) printf 'exists\nrunning\nrestart\nexists\nlogs -n 80 dx-wait\n' ;;
            s) : ;;
        esac
    done
}

ws_why=""
ws_check() { # ws_check WHAT ACTUAL EXPECTED
    [ "$2" = "$3" ] && return 0
    ws_why="${ws_why}${ws_why:+; }$1 was [$(printf '%s' "$2" | tr '\n' '|')], expected [$(printf '%s' "$3" | tr '\n' '|')]"
}
ws_report() {
    if [ -z "$ws_why" ]; then test_pass "$1"; else test_fail "$1 ($ws_why)"; fi
    ws_why=""
}
# ws_ready FAILED_PROBES CALL_KIND... / ws_stopped ...: the whole outcome of a
# wait that ends ready, or that the third stopped reading ends.
ws_ready() {
    local failed="$1"
    shift
    ws_check "exit status" "$ws_rc" 0
    ws_check "stdout" "$(ws_file out)" "$(ws_ready_out "$failed")"
    ws_check "stderr" "$(ws_file err)" ""
    ws_check "call log" "$(ws_file calls)" "$(ws_calls "$@")"
}
ws_stopped() {
    local failed="$1"
    shift
    ws_check "exit status" "$ws_rc" 1
    ws_check "probes" "$(ws_file probes)" "$((failed + 1))"
    ws_check "stdout" "$(ws_file out)" "$(ws_stopped_out "$failed")"
    ws_check "stderr" "$(ws_file err)" "$(stop_text)"
    ws_check "call log" "$(ws_file calls)" "$(ws_calls "$@")"
}

stub_run WS_READINGS="run stop run" WS_SUCCEED_AT=4
ws_ready 3 f f f s
ws_report "case 1: one stopped reading among running ones: Guest is ready., rc 0, no stop text, no log pull"

stub_run WS_READINGS="run stop stop run" WS_SUCCEED_AT=6
ws_ready 5 f f f f f s
ws_report "case 2: two consecutive stopped readings, then running: no abort"

stub_run WS_READINGS="stop stop run stop stop" WS_SUCCEED_AT=6
ws_ready 5 f f f f f s
ws_report "case 3: stopped, stopped, running, stopped, stopped, then SSH answers: no abort (the count resets)"

stub_run WS_READINGS="run run stop"
ws_stopped 4 f f f f x
ws_report "case 4: stopped from probe 3 on: stops on failed probe 5 exactly, no further probe, the D-3 text and 80-line tail, rc 1, no timeout text"

stub_run WS_READINGS="stop"
ws_stopped 2 f f x
ws_report "case 4 (k = 1): stopped from the first probe: stops on failed probe 3 exactly"

stub_run WS_READINGS="stop stop gone stop stop err stop stop run stop stop stop"
ws_stopped 11 f f g f f g f f f f f x
ws_report "case 5: stopped readings broken by an absent container, a failed exists query and a running reading: only the three consecutive ones on probes 10-12 stop the wait"

stub_run WS_READINGS="run run stop" WS_RESTARTS="4 4 4 6"
ws_check "exit status" "$ws_rc" 1
ws_check "probes" "$(ws_file probes)" 3
ws_check "stdout" "$(ws_file out)" "$(ws_stopped_out 2)"
ws_check "stderr" "$(ws_file err)" "$(crash_text 4 6)"
ws_check "call log" "$(ws_file calls)" "$(ws_calls f f c)"
ws_report "case 6: a restart count up by 2 on the first stopped reading aborts at once with the crash-loop text, not the stop text"

stub_run WS_READINGS="stop" WS_JUMP_AT=2 WS_JUMP_TO=4000
ws_check "exit status" "$ws_rc" 1
ws_check "probes" "$(ws_file probes)" 2
ws_check "stdout" "$(ws_file out)" "$(ws_stopped_out 1)"
ws_check "stderr" "$(ws_file err)" "$(timeout_text)"
ws_check "call log" "$(ws_file calls)" "$(ws_calls f t)"
ws_report "case 7: the timeout reached on the second stopped reading: the timeout report, rc 1, no stop text"

# Case 9 (D-4): names a leftover count, threshold or setting could plausibly
# carry; with 1, 2 or 99 in every one of them a wait still needs exactly three
# fresh stopped readings.
for leftover in 1 2 99; do
    ws_env=()
    for name in DXE_WAIT_STOPPED_READINGS DX_WAIT_STOPPED_READINGS DXE_WAIT_STOP_COUNT DX_WAIT_STOP_COUNT \
        DXE_STOPPED_READINGS DX_STOPPED_READINGS DX_CONTAINER_STOPPED_READINGS DXE_CONTAINER_STOPPED_READINGS \
        DX_SSH_STOPPED_READINGS DX_SSH_STOP_READINGS DX_SSH_STOP_CONFIRM DX_WAIT_STOP_READINGS DXE_WAIT_STOP_READINGS \
        DX_WAIT_STOP_CONFIRM DXE_WAIT_STOP_CONFIRM DX_STOP_CONFIRM_READINGS DX_SSH_STOP_THRESHOLD \
        STOPPED_READINGS stopped_readings stop_count; do
        ws_env+=("$name=$leftover")
    done
    stub_run "${ws_env[@]}" WS_READINGS="stop stop" WS_SUCCEED_AT=3
    ws_ready 2 f f s
    stub_run "${ws_env[@]}" WS_READINGS="stop"
    ws_stopped 2 f f x
    ws_report "case 9 (D-4): with $leftover left in every plausible count or threshold variable, two stopped readings do not stop the wait and the third (not an earlier or later one) does"
done

# Case 9 (D-4): two waits in one shell -- wait_ssh_main twice after sourcing
# the copy. The first ends ready after two stopped readings; the second must
# still take three fresh ones.
cat > "$fixture/two-waits.sh" <<'PROBE'
set -euo pipefail
out="$1"
source "$2"
WS_STATE="$out/wait1"
export WS_STATE
mkdir -p "$WS_STATE"
WS_READINGS="stop stop"
WS_SUCCEED_AT=3
wait_ssh_main > "$out/wait1.out" 2> "$out/wait1.err"
printf 'first wait returned\n' > "$out/marker"
WS_STATE="$out/wait2"
mkdir -p "$WS_STATE"
WS_READINGS=stop
WS_SUCCEED_AT=99999
wait_ssh_main > "$out/wait2.out" 2> "$out/wait2.err"
printf 'second wait returned\n' >> "$out/marker"
PROBE
tw="$fixture/two-waits"
mkdir -p "$tw"
tw_rc=0
env PATH="$stub_tools:/usr/bin:/bin" TMPDIR="$fixture/tmp" "$BASH" "$fixture/two-waits.sh" "$tw" "$fixture/stub-bin/dx-wait-ssh" > "$tw/run.out" 2>&1 || tw_rc=$?
ws_check "exit status of the shell" "$tw_rc" 1
ws_check "progress marker" "$(cat "$tw/marker" 2>/dev/null || true)" "first wait returned"
ws_check "first wait stdout" "$(cat "$tw/wait1.out" 2>/dev/null || true)" "$(ws_ready_out 2)"
ws_check "first wait stderr" "$(cat "$tw/wait1.err" 2>/dev/null || true)" ""
ws_check "second wait probes" "$(cat "$tw/wait2/probes" 2>/dev/null || true)" 3
ws_check "second wait stdout" "$(cat "$tw/wait2.out" 2>/dev/null || true)" "$(ws_stopped_out 2)"
ws_check "second wait stderr" "$(cat "$tw/wait2.err" 2>/dev/null || true)" "$(stop_text)"
ws_check "second wait call log" "$(cat "$tw/wait2/calls" 2>/dev/null || true)" "$(ws_calls f f x)"
[ -z "$ws_why" ] || ws_why="$ws_why; shell output: $(tr '\n' '|' < "$tw/run.out")"
ws_report "case 9 (D-4): a second wait in the same shell, after one that ended on two stopped readings, needs three fresh stopped readings"

stub_run WS_READINGS="run stop stop run gone stop err run" WS_SUCCEED_AT=9
ws_ready 8 f f f f g f g f s
ws_check "exists queries" "$(grep -cx exists "$WS_STATE/calls" || true)" 8
ws_check "running queries" "$(grep -cx running "$WS_STATE/calls" || true)" 6
ws_check "DX_SLEEP calls" "$(grep -cx 'sleep 1' "$WS_STATE/calls" || true)" 8
ws_check "external sleep calls" "$(grep -c 'external sleep' "$WS_STATE/calls" || true)" 0
ws_report "case 10 (D-2): per failed probe exactly one reading (one exists query, one running query when it exists) and exactly one DX_SLEEP call; no other sleep"

# --- C. through the real adapters, only the CLI faked -------------------------
test_section "dx-wait-ssh through the real Apple and docker-ssh adapters (fake CLI)"
ad_tools="$(fake_tool_dir_create "$fixture")" || exit 1
fake_tool_write "$ad_tools" sleep 'printf "external sleep %s\n" "$*" >> "$WS_STATE/calls"'
fake_tool_write "$ad_tools" uname 'case "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac'
fake_qnap_ssh_write "$ad_tools"
[ -x "$ad_tools/ssh" ] || { echo "test setup: fake ssh missing in $ad_tools" >&2; exit 1; }
# Both fakes log their argv to $WS_STATE/cli and read the reading for the
# current probe from WS_CLI_READINGS (token N on failed probe N, the last one
# repeating): R running, S stopped, A absent, Q/T the exists query fails, F
# the running query fails after exists succeeded. WS_EMPTY_CALL (Apple) and
# WS_FAIL_CALL (docker) make exactly that one running query glitch.
cat > "$fixture/fake-container.body" <<'FAKE'
printf '%s\n' "$*" >> "$WS_STATE/cli"
n=$(cat "$WS_STATE/probes" 2>/dev/null || echo 0)
tok=R
i=0
for t in ${WS_CLI_READINGS:-R}; do
    tok=$t
    i=$((i + 1))
    [ "$i" -lt "$n" ] || break
done
case "$*" in
    "list -a --quiet")
        case "$tok" in
            A) printf 'other-guest\n' ;;
            Q) echo "fake container: XPC connection interrupted" >&2; exit 1 ;;
            *) printf 'other-guest\ndx-wait\n' ;;
        esac ;;
    "list --quiet")
        c=$(( $(cat "$WS_STATE/list-quiet-calls" 2>/dev/null || echo 0) + 1 ))
        echo "$c" > "$WS_STATE/list-quiet-calls"
        # The load glitch: an empty listing with exit 0.
        if [ "$c" = "${WS_EMPTY_CALL:-0}" ]; then exit 0; fi
        case "$tok" in
            S) printf 'other-guest\n' ;;
            F) echo "fake container: XPC connection interrupted" >&2; exit 1 ;;
            *) printf 'other-guest\ndx-wait\n' ;;
        esac ;;
    # The tabular fallback runs only after a --quiet listing failed; it fails too.
    "list -a"|"list") exit 1 ;;
    "logs -n 80 dx-wait") printf 'guest log line 1\nguest log line 2\n' ;;
    *) echo "fake container: unexpected call: $*" >&2; exit 98 ;;
esac
FAKE
cat > "$fixture/fake-docker.body" <<'FAKE'
printf '%s\n' "$*" >> "$WS_STATE/cli"
n=$(cat "$WS_STATE/probes" 2>/dev/null || echo 0)
tok=R
i=0
for t in ${WS_CLI_READINGS:-R}; do
    tok=$t
    i=$((i + 1))
    [ "$i" -lt "$n" ] || break
done
case "$*" in
    "container inspect dx-wait")
        case "$tok" in
            A) echo "Error: No such object: dx-wait" >&2; exit 1 ;;
            T) echo "fake docker: error during connect: connection reset" >&2; exit 255 ;;
            *) echo '[{"Name":"/dx-wait"}]' ;;
        esac ;;
    "container inspect --format {{.State.Running}} dx-wait")
        c=$(( $(cat "$WS_STATE/running-calls" 2>/dev/null || echo 0) + 1 ))
        echo "$c" > "$WS_STATE/running-calls"
        if [ "$c" = "${WS_FAIL_CALL:-0}" ]; then echo "fake docker: error during connect: connection reset" >&2; exit 1; fi
        case "$tok" in
            S) printf 'false\r\n' ;;
            F) echo "fake docker: error during connect: connection reset" >&2; exit 1 ;;
            *) printf 'true\r\n' ;;
        esac ;;
    "container inspect --format {{.RestartCount}} dx-wait") printf '0\r\n' ;;
    "logs -n 80 dx-wait") printf 'guest log line 1\nguest log line 2\n' ;;
    *) echo "fake docker: unexpected call: $*" >&2; exit 98 ;;
esac
FAKE
fake_tool_write "$ad_tools" container "$(cat "$fixture/fake-container.body")"
fake_tool_write "$ad_tools" docker "$(cat "$fixture/fake-docker.body")"
apple_run() { ws_run "$fixture/adapter-bin" "$ad_tools" DX_RUNTIME=apple "$@"; }
docker_run() {
    ws_run "$fixture/adapter-bin" "$ad_tools" DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid \
        DXE_RUNTIME_DOCKER_BIN=docker DX_GUEST_SYSTEM=x86_64-linux "$@"
}
# The stub log of an adapter run: probes and sleeps only.
ad_calls() { # ad_calls FAILED_PROBES_THAT_SLEEP LAST_PROBE
    local n=0
    while [ "$n" -lt "$1" ]; do
        n=$((n + 1))
        printf 'probe %s\nsleep 1\n' "$n"
    done
    printf 'probe %s\n' "$2"
}
# ap_cli KIND... -- Apple CLI argv per failed probe: f both listings, a only
# the -a listing (absent), q the -a listing failing into its fallback, e the
# running listing failing into its fallback, x a third stopped reading (then
# the 80-line log request).
ap_cli() {
    local kind
    for kind in "$@"; do
        case "$kind" in
            f) printf 'list -a --quiet\nlist --quiet\n' ;;
            a) printf 'list -a --quiet\n' ;;
            q) printf 'list -a --quiet\nlist -a\n' ;;
            e) printf 'list -a --quiet\nlist --quiet\nlist\n' ;;
            x) printf 'list -a --quiet\nlist --quiet\nlogs -n 80 dx-wait\n' ;;
        esac
    done
}
# dk_cli KIND... -- docker argv: the baseline restart count, then per failed
# probe f (exists, running, restart count), g (exists failed, restart count)
# or x (a third stopped reading: exists, running, then the 80-line logs).
dk_cli() {
    local kind
    printf 'container inspect --format {{.RestartCount}} dx-wait\n'
    for kind in "$@"; do
        case "$kind" in
            f) printf 'container inspect dx-wait\ncontainer inspect --format {{.State.Running}} dx-wait\ncontainer inspect --format {{.RestartCount}} dx-wait\n' ;;
            g) printf 'container inspect dx-wait\ncontainer inspect --format {{.RestartCount}} dx-wait\n' ;;
            x) printf 'container inspect dx-wait\ncontainer inspect --format {{.State.Running}} dx-wait\nlogs -n 80 dx-wait\n' ;;
        esac
    done
}
ad_ready() { # ad_ready FAILED_PROBES EXPECTED_CLI
    ws_check "exit status" "$ws_rc" 0
    ws_check "stdout" "$(ws_file out)" "$(ws_ready_out "$1")"
    ws_check "stderr" "$(ws_file err)" ""
    ws_check "stub log" "$(ws_file calls)" "$(ad_calls "$1" "$(($1 + 1))")"
    ws_check "CLI calls" "$(ws_file cli)" "$2"
}
ad_stopped() { # ad_stopped FAILED_PROBES_BEFORE EXPECTED_CLI
    ws_check "exit status" "$ws_rc" 1
    ws_check "probes" "$(ws_file probes)" "$(($1 + 1))"
    ws_check "stdout" "$(ws_file out)" "$(ws_stopped_out "$1")"
    ws_check "stderr" "$(ws_file err)" "$(stop_text)"
    ws_check "stub log" "$(ws_file calls)" "$(ad_calls "$1" "$(($1 + 1))")"
    ws_check "CLI calls" "$(ws_file cli)" "$2"
}

apple_run WS_EMPTY_CALL=2 WS_SUCCEED_AT=4
ad_ready 3 "$(ap_cli f f f)"
ws_report "case 8 (Apple): one empty \`container list --quiet\` (exit 0) while \`list -a --quiet\` lists the guest: no abort, Guest is ready., one listing pair per failed probe"

apple_run WS_CLI_READINGS=S
ad_stopped 2 "$(ap_cli f f x)"
ws_report "case 8 (Apple): a persistent stop still stops the wait on the third reading, with the D-3 text and \`container logs -n 80\`"

docker_run WS_FAIL_CALL=2 WS_SUCCEED_AT=4
ad_ready 3 "$(dk_cli f f f)"
ws_report "case 8 (docker-ssh): one failed \`inspect --format {{.State.Running}}\` after \`inspect\` succeeded: no abort, Guest is ready., one exists and one running inspect per failed probe"

docker_run WS_CLI_READINGS=S
ad_stopped 2 "$(dk_cli f f x)"
ws_report "case 8 (docker-ssh): a persistent stop (State.Running false) still stops the wait on the third reading, with the D-3 text and \`docker logs -n 80\`"

docker_run WS_CLI_READINGS="S S A S S T S S R S F S"
ad_stopped 11 "$(dk_cli f f g f f g f f f f f x)"
ws_report "case 5 (docker-ssh): an absent container and a failed exists inspect reset the count, a failed running inspect counts as stopped (D-1): only probes 10-12 stop the wait"

apple_run WS_CLI_READINGS="S S A S S Q S S R S F S"
ad_stopped 11 "$(ap_cli f f a f f q f f f f e x)"
ws_report "case 5 (Apple): an absent container and a failed -a listing reset the count, a failed running listing counts as stopped (D-1): only probes 10-12 stop the wait"

print_summary
exit_with_code
