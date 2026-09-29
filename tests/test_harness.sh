#!/bin/bash
# tier: unit
# bash32: yes
set -euo pipefail

# tests/test_harness.sh -- Red for WP1.1 / Fable D1: tests/lib/harness.sh.
#
# Sources tests/lib/harness.sh directly, NOT tests/test_helpers.sh, so the
# harness's contract is proven standalone before test_helpers.sh's shims
# (test_pass/test_fail/print_summary/exit_with_code, WP1.1's Refactor step)
# are layered on top of it. Because of that, this file cannot grade the
# harness using the harness's own primitives -- a self-consistent bug (say,
# expect_exit always recording "pass" regardless of the actual exit code)
# would then pass its own regression test. So, like
# tests/test_refactor_contracts.sh, it carries its own tiny, independent
# check()/reject()/contains() vocabulary and calls the harness only as the
# code under test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0
check() { if "$@"; then :; else echo "FAIL: $*" >&2; failures=$((failures + 1)); fi; }
reject() { ! "$@"; }
contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- (k) Import purity, run before anything below gives this shell its own
# $DXE_TEST_RESULTS -- the identical eight-way contract
# tests/test_refactor_contracts.sh applies to bin/lib/*.sh (its lines
# 10-33); the same shape lands on tests/lib/*.sh in WP1.6. Sourced inside
# its own command substitution (a subshell), so whatever state the harness
# sets while loading cannot leak back and contaminate the cases that
# follow.
purity_ok() {
    local before_flags="$-" before_ifs="$IFS" before_pwd="$PWD" before_umask before_traps
    before_umask="$(umask)"
    before_traps="$(trap -p)"
    local purity_stderr
    purity_stderr="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-purity.XXXXXX")"
    local output status
    output="$(source "$SCRIPT_DIR/lib/harness.sh" 2>"$purity_stderr")" && status=0 || status=$?
    local stderr_output
    stderr_output="$(cat "$purity_stderr")"
    rm -f "$purity_stderr"
    [ -z "$output" ] &&
        [ -z "$stderr_output" ] &&
        [ "$status" -eq 0 ] &&
        [ "$before_flags" = "$-" ] &&
        [ "$before_ifs" = "$IFS" ] &&
        [ "$before_pwd" = "$PWD" ] &&
        [ "$before_umask" = "$(umask)" ] &&
        [ "$before_traps" = "$(trap -p)" ] &&
        [ -z "${DXE_TEST_RESULTS:-}" ]
}
check purity_ok

# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# This shell's own results file, isolated from anything else on the
# filesystem and from other suites -- set explicitly (rather than letting
# the harness lazily mktemp one) so every check below knows exactly which
# file to inspect.
RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-selftest.XXXXXX")"
DXE_TEST_RESULTS="$RESULTS"
export DXE_TEST_RESULTS

record_count() { wc -l < "$RESULTS" | tr -d ' '; }
last_record() { tail -n1 "$RESULTS"; }

# --- (a) expect_exit 3 bash -c 'exit 3' passes.
n_before="$(record_count)"
expect_exit 3 bash -c 'exit 3' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass

# --- (b) expect_exit 0 false fails, and the failure is recorded, printing
# the captured stdout, stderr and actual exit status.
n_before="$(record_count)"
b_out="$(expect_exit 0 false)"
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = fail
check contains "$b_out" "expected exit 0"
check contains "$b_out" "got 1"

# --- (c) ( expect_exit 0 false ) inside a REAL subshell is still recorded
# -- the exact idiom that lost results before D1
# (tests/test_refactor_contracts.sh's F6 comment: "test_pass/test_fail
# called *inside* a ( … ) subshell incremented counters that die with the
# subshell").
n_before="$(record_count)"
( expect_exit 0 false >/dev/null )
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = fail

# --- (d) a failing expect_stdout prints the captured stdout. Run in a
# nested bash -c with its own DXE_TEST_RESULTS (so this process's file, and
# the counts already asserted above, are untouched), and assert the nested
# process's own output contains the captured text.
nested_results="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-nested.XXXXXX")"
d_out="$(SCRIPT_DIR="$SCRIPT_DIR" DXE_TEST_RESULTS="$nested_results" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    expect_stdout "goodbye" printf "hello world"
')"
check contains "$d_out" "hello world"
check test "$(wc -l < "$nested_results" | tr -d ' ')" -eq 1
check grep -q "^fail	" "$nested_results"
rm -f "$nested_results"

# --- (e) expect_stdout 'hello' printf 'hello world' passes.
n_before="$(record_count)"
expect_stdout 'hello' printf 'hello world' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass

# --- (f) expect_stderr matches, and a failing expect_stderr prints the
# captured stderr.
n_before="$(record_count)"
expect_stderr 'boom' bash -c 'echo boom >&2' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass
f_out="$(expect_stderr 'nomatch' bash -c 'echo boom >&2')"
check test "$(last_record | cut -f1)" = fail
check contains "$f_out" "boom"

# --- (g) expect_file_eq passes on an exact match, fails otherwise.
g_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-file.XXXXXX")"
printf 'exact contents' > "$g_file"
n_before="$(record_count)"
expect_file_eq "$g_file" 'exact contents' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass
n_before="$(record_count)"
expect_file_eq "$g_file" 'wrong contents' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = fail
rm -f "$g_file"

# --- (h) finish exits non-zero when zero cases were recorded (nested bash,
# its own empty results file).
if SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-empty.XXXXXX")"
    export DXE_TEST_RESULTS
    finish
' >/dev/null 2>&1; then
    h_status=0
else
    h_status=$?
fi
check test "$h_status" -ne 0

# --- (i) finish exits non-zero when one case failed, and zero when every
# recorded case passed.
if SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-onefail.XXXXXX")"
    export DXE_TEST_RESULTS
    expect_exit 0 false >/dev/null
    expect_exit 0 true >/dev/null
    finish
' >/dev/null 2>&1; then
    i_fail_status=0
else
    i_fail_status=$?
fi
check test "$i_fail_status" -ne 0

if SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-allpass.XXXXXX")"
    export DXE_TEST_RESULTS
    expect_exit 0 true >/dev/null
    expect_exit 3 bash -c "exit 3" >/dev/null
    finish
' >/dev/null 2>&1; then
    i_pass_status=0
else
    i_pass_status=$?
fi
check test "$i_pass_status" -eq 0

# --- (j) skip --class live "reason" records a skip line with the class.
n_before="$(record_count)"
skip --class live "container not running"
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = skip
check test "$(last_record | cut -f2)" = live
check contains "$(last_record)" "container not running"

# --- it() names the case the following expect_* call records.
n_before="$(record_count)"
it "custom label for this case"
expect_exit 0 true >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check contains "$(last_record)" "custom label for this case"

rm -f "$RESULTS"

[ "$failures" -eq 0 ]
