#!/bin/bash
# tests/lib/harness.sh -- capture-based assertions with a results file that
# survives subshells and background jobs (Fable D1 / WP1.1).
#
# `test_pass`/`test_fail` (tests/test_helpers.sh) increment TESTS_PASSED/
# TESTS_FAILED in whichever shell calls them. A case recorded inside a
# `( ... )` subshell -- or a background job -- dies with that subshell: the
# counters revert to whatever the PARENT shell had, and the caller never
# learns a real failure happened (tests/test_refactor_contracts.sh's F6
# section exists only to prove that regression can still be caught).
# Fable D1's fix is this file: record each case as one line appended to a
# plain file instead of an in-memory counter. A file survives a subshell
# exiting -- only the counting SHELL's variables die with it, the write
# already landed on disk -- and an append (`>>`, opened O_APPEND) from a
# background job lands safely too, since each record here is one short
# `printf`, well under the platform's atomic pipe/write buffer, so
# concurrent short appends do not interleave into a corrupt line.
#
# Import-pure: sourcing this file only defines functions and one default
# variable (DXE_HARNESS_LABEL=""), with no I/O, no `exit`, and no change to
# the sourcing shell's control state ($-, IFS, PWD, umask, traps) -- the
# same eight-way contract tests/test_refactor_contracts.sh runs over
# bin/lib/*.sh (its lines 10-33), proven for this file by
# tests/test_harness.sh's own purity_ok case.
#
# $DXE_TEST_RESULTS is deliberately NOT created here at source time, only
# lazily, in _dxe_harness_results_file, the first time some function
# actually needs to record or read a case. This is what keeps each test
# suite's results private to itself: tests/run_all_tests.sh sources
# tests/test_helpers.sh (which sources this file) purely to reuse its
# shared setup, then runs every suite as `bash "$test_file"` -- a brand new
# process. If sourcing alone created and exported DXE_TEST_RESULTS in the
# runner, every suite it then launches would inherit that one export and
# all 30-odd suites would append into the SAME file, and a later suite's
# summary would include an earlier suite's cases. Because nothing here
# touches the variable until a case is actually recorded, and the runner
# itself never records one (it only forwards to `bash "$test_file"` and
# reads its exit code), the runner's own shell never sets or exports it.
# Each suite process, sourcing test_helpers.sh (and so this file) itself,
# is the first shell to call it/expect_*/skip/finish in its own execution,
# and so gets its own fresh mktemp file, private to that one
# `bash "$test_file"` process tree (subshells and background jobs of THAT
# process still see it without any export, since they are forks of it, not
# fresh interpreter invocations reading a fresh environment, and inherit
# every shell variable automatically; export only matters for a genuinely
# new `bash`/`bash -c` invocation, which is why it is exported here at all
# -- for the nested-bash cases this file's own test deliberately drives).
#
# Bash 3.2 host note (this file is sourced by tests/test_harness.sh under
# /bin/bash directly, per tests/run-bash32-tests.sh, and by every other
# suite via test_helpers.sh on this Mac's default /bin/bash): no
# `declare -A`, no namerefs, no `mapfile`, no `${var,,}`, no
# `local var=$(...)` (a real Bash 3.2 bug: `local` swallows the command
# substitution's exit status, so a failing command inside one never trips
# a caller's `set -e` -- every assignment here that calls a command splits
# `local var` from `var=$(...)` onto its own line instead).

# Colors, matching tests/test_helpers.sh's exactly, so `finish`'s summary
# line renders identically to `print_summary`'s. This file does not, and
# must not, source test_helpers.sh -- it has to stand on its own so
# test_helpers.sh can source IT instead, the direction WP1.1 requires
# (tests/test_harness.sh proves this file works with nothing but itself).
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# The label `it` set for whichever `expect_*` call comes next. It persists
# until the next `it` call -- it is not consumed after a single use: `it
# "does X"` followed by several `expect_*` calls names all of them "does
# X", matching `it` reading as "describe the case(s) now under test" more
# than a one-shot label. An `expect_*` call with no preceding `it` in the
# calling shell falls back to a label built from its own arguments.
DXE_HARNESS_LABEL=""

it() {
    DXE_HARNESS_LABEL="$1"
}

# Ensure $DXE_TEST_RESULTS names a real, writable, append-only file,
# creating one with mktemp under ${TMPDIR:-/tmp} the first time it is
# needed, if the caller has not already set one. See the file header for
# why this must stay lazy rather than running at source time.
_dxe_harness_results_file() {
    if [ -z "${DXE_TEST_RESULTS:-}" ]; then
        local file
        file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-results.XXXXXX")"
        DXE_TEST_RESULTS="$file"
        export DXE_TEST_RESULTS
    fi
}

# Append one pass/fail record. $1: pass|fail. $2: the case label.
_dxe_harness_record() {
    _dxe_harness_results_file
    printf '%s\t%s\n' "$1" "$2" >> "$DXE_TEST_RESULTS"
}

# Count of recorded lines of one kind (pass|fail|skip). The `-s` guard
# means a not-yet-created or still-empty results file reads as zero
# without ever invoking awk on a missing path.
_dxe_harness_count() {
    if [ -s "$DXE_TEST_RESULTS" ]; then
        awk -F'\t' -v want="$1" '$1 == want { c++ } END { print c + 0 }' "$DXE_TEST_RESULTS"
    else
        printf '0\n'
    fi
}

# expect_exit N cmd [args...]
#
# Runs cmd, capturing stdout, stderr and its exit status, without letting a
# non-zero status trip the CALLER's own `set -e`: this function always
# returns 0 itself, the same shape tests/test_refactor_state_machines.sh's
# expect_ok/expect_reject already use (their `if/then/else` always lands on
# a test_pass/test_fail call, and those always return 0) -- a case's
# pass/fail lives in the results file, not in this call's own exit status.
# Passes if the exit status equals N; otherwise records a failure and
# prints the captured stdout, stderr and actual exit status, so a Red run
# explains itself without anything having to be re-run by hand.
expect_exit() {
    local expected="$1"
    shift
    local label="${DXE_HARNESS_LABEL:-expect_exit $expected: $*}"
    local out_file err_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-out.XXXXXX")"
    err_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-err.XXXXXX")"
    local status
    if "$@" >"$out_file" 2>"$err_file"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq "$expected" ]; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected exit $expected, got $status"
        echo "  stdout:"
        sed 's/^/    /' "$out_file"
        echo "  stderr:"
        sed 's/^/    /' "$err_file"
    fi
    rm -f "$out_file" "$err_file"
    return 0
}

# expect_stdout PATTERN cmd [args...]
#
# Runs cmd (its exit status is not checked); passes if its stdout matches
# PATTERN as an ERE (`grep -E`). On failure, prints the captured stdout.
# grep reads it from a completed file here, never from a live pipe, so
# this is not the `writer | grep -q` SIGPIPE-under-pipefail hazard
# documented at the top of tests/test_helpers.sh (stdin_matches).
expect_stdout() {
    local pattern="$1"
    shift
    local label="${DXE_HARNESS_LABEL:-expect_stdout $pattern: $*}"
    local out_file err_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-out.XXXXXX")"
    err_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-err.XXXXXX")"
    "$@" >"$out_file" 2>"$err_file" || true
    if grep -Eq -- "$pattern" "$out_file"; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected stdout to match (ERE): $pattern"
        echo "  captured stdout:"
        sed 's/^/    /' "$out_file"
    fi
    rm -f "$out_file" "$err_file"
    return 0
}

# expect_stderr PATTERN cmd [args...] -- expect_stdout's mirror, over stderr.
expect_stderr() {
    local pattern="$1"
    shift
    local label="${DXE_HARNESS_LABEL:-expect_stderr $pattern: $*}"
    local out_file err_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-out.XXXXXX")"
    err_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-err.XXXXXX")"
    "$@" >"$out_file" 2>"$err_file" || true
    if grep -Eq -- "$pattern" "$err_file"; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected stderr to match (ERE): $pattern"
        echo "  captured stderr:"
        sed 's/^/    /' "$err_file"
    fi
    rm -f "$out_file" "$err_file"
    return 0
}

# expect_file_eq FILE EXPECTED_STRING -- exact-match FILE's whole content
# (trailing newlines stripped by the command substitution that reads it,
# same as any other `$(cat ...)` in this codebase) against EXPECTED_STRING.
expect_file_eq() {
    local file="$1" expected="$2"
    local label="${DXE_HARNESS_LABEL:-expect_file_eq $file}"
    local actual
    actual="$(cat "$file" 2>/dev/null)" || actual=""
    if [ "$actual" = "$expected" ]; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
    return 0
}

# skip --class live|linux-root|destructive "reason"
skip() {
    local class="" reason=""
    if [ "${1:-}" = "--class" ]; then
        class="${2:-}"
        reason="${3:-}"
    else
        reason="${1:-}"
    fi
    _dxe_harness_results_file
    printf 'skip\t%s\t%s\n' "$class" "$reason" >> "$DXE_TEST_RESULTS"
}

# finish -- prints the same summary line print_summary does (byte-identical
# format, different data source), then exits non-zero if any case failed,
# OR if zero cases were recorded at all: a suite that records nothing is
# not a suite that passed. This last rule is deliberately NOT shared with
# test_helpers.sh's exit_with_code shim -- several existing suites
# legitimately record 0 passed / 1 skipped when no container is present
# (e.g. test_section19_reverse_forward.sh) and must keep exiting 0; only
# callers of this native `finish` opt into the stricter rule.
finish() {
    _dxe_harness_results_file
    local passed failed skipped total
    passed="$(_dxe_harness_count pass)"
    failed="$(_dxe_harness_count fail)"
    skipped="$(_dxe_harness_count skip)"
    total=$((passed + failed + skipped))
    echo ""
    echo "=============================="
    echo -e "Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}, ${YELLOW}${skipped} skipped${NC}"
    echo "=============================="
    local status=0
    if [ "$failed" -gt 0 ] || [ "$total" -eq 0 ]; then
        status=1
    fi
    rm -f "$DXE_TEST_RESULTS"
    exit "$status"
}
