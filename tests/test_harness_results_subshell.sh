#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
set -uo pipefail

# tests/test_harness_results_subshell.sh -- Red for WP-HARNESS-RES: a case
# recorded in a subshell `( … )`, a command substitution `$( … )` or a
# background job `&` reaches its suite's tally even when it is among the
# suite's FIRST records.
#
# The hazard (tests/lib/harness.sh at 4af0505): _dxe_harness_results_file
# creates $DXE_TEST_RESULTS lazily, in whichever process records first, and
# keys ownership on $$. A subshell shares its parent's $$ but not its
# variables, so when the first records come from forks, each fork mints a
# private file, exports the path only inside itself and exits; the suite's
# top-level shell never sees those files and later mints its own. Every such
# case is lost from print_summary / exit_with_code / finish, failures
# included: a suite prints "✗ FAIL", reports "0 failed" and exits 0 (or,
# with finish, reports "zero cases" and exits 3), and the forks' files are
# left behind in TMPDIR.
#
# Interface contract (WP-HARNESS-RES):
#
#  1. One file per suite process, whoever records first. A suite process is
#     a bash process that sources tests/test_helpers.sh or tests/lib/harness.sh
#     and records cases. Every case recorded by that process, or by any
#     `( … )` subshell, `$( … )` command substitution or `&` background job
#     forked from it (a job the suite waits for), is counted exactly once by
#     that process's print_summary, exit_with_code and finish -- whichever
#     of them records first, and even when ALL of them are forks. Nothing
#     needs to run first at the top level: the probes below record from a
#     fork before any other harness call (no test_section, no it, no record).
#     Observable:
#       - print_summary prints "Results: P passed, F failed, S skipped"
#         (colour codes aside) with the true totals, and, when F > 0, its
#         "Failed cases (from the results file):" list names every failed
#         case once (each failure's own "  ✗ FAIL: <label>" line therefore
#         appears twice in the output: once live, once in the list);
#       - exit_with_code exits 1 when any case failed, else 0;
#       - finish prints the same "Results:" line ("Skipped classes:" too)
#         and exits 1 when any case failed, 0 when cases passed and none
#         failed, and 3 only when no case at all was recorded -- a suite
#         whose cases all came from forks is not a "zero cases" suite.
#  2. Isolation, unchanged. A new interpreter (`bash FILE`) is a different
#     suite process: it never appends to, adopts or removes its parent's
#     file, and the parent never counts its cases -- whether the parent's
#     own first records came from a fork or from its top level. An inherited
#     DXE_TEST_RESULTS whose DXE_TEST_RESULTS_OWNER is not the recording
#     process is never appended to, counted or removed, and no other
#     dxe-harness-results.* file in the same TMPDIR is counted or touched.
#  3. Lazy, unchanged. Sourcing tests/lib/harness.sh or tests/test_helpers.sh
#     by itself creates no file, leaves DXE_TEST_RESULTS empty, and exports
#     neither DXE_TEST_RESULTS nor DXE_TEST_RESULTS_OWNER, so a child started
#     after sourcing alone inherits neither. tests/run.sh owns no results
#     file: the suite it runs starts with neither variable set, and a failure
#     recorded in that suite's fork fails the run ("FAIL: NAME failed.",
#     "Some tests FAILED.", exit 1).
#  4. Fail-closed, unchanged. When the results file cannot be created (a
#     TMPDIR that does not exist), a suite whose records come from forks
#     still stops non-zero with the harness's "results file" error: no case
#     result line, no "Results:" summary, nothing after exit_with_code/finish.
#     Also unchanged (pinned elsewhere, by tests/test_tmpdir_failure_safety.sh
#     section 3, which detects a suite's first failure as a failing `mktemp`
#     call through a PATH wrapper): the results file is still made by mktemp
#     found on PATH, so with TMPDIR missing the first failure is a mktemp
#     call. Creating it by shell redirection alone breaks that suite's
#     missing-TMPDIR decoy runs of test_section3_bootstrap.sh,
#     test_section6_tools.sh and test_section17_dx_ai_runtime.sh ("no mktemp
#     failure was seen at all").
#  5. Nothing left behind. A suite that ends through exit_with_code or finish
#     leaves its TMPDIR exactly as it found it: no dxe-harness-results.* file
#     (nor any other file) from it or from its forks remains.
#
# Where the fix lives is the implementer's choice; only the behaviour above is
# pinned. Note that a fork cannot hand a path back to its parent, so whatever
# the parent later reads has to be agreed BEFORE the fork, without I/O at
# source time (item 3): e.g. a name chosen at source time (unexported, not
# re-chosen by a fork that re-sources the file) or derived from $$ (PIDs are
# reused, so a stale file of that name must not be adopted). Concurrent
# background jobs may race to create it (case G); one way that keeps item 4
# is to mktemp a file beside the agreed name and `ln` it there (atomic: a
# fork that linked first wins, the others adopt its file).
#
# Grading. The code under test is the harness itself, so -- like
# tests/test_harness.sh -- this file grades with its own small vocabulary
# (hr_check), records nothing through the harness, and decides its exit
# status from its own counter. Every probe is a FILE run with bash, as its own
# suite process, with its own empty TMPDIR inside this file's scratch
# directory; the checks read the probe's output, its exit status and what it
# left in its TMPDIR. hr_* helpers are never called inside a fork.
#
# Safety: the only TMPDIR that is broken on purpose (case O) is a missing
# directory inside this file's scratch directory, used by a probe that runs a
# DECOY copy of tests/test_helpers.sh and tests/lib/ from that scratch
# directory (cwd included), never the checkout. No probe runs a destructive
# command. Each probe is bounded in time (perl alarm, HR_BOUND seconds).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourced for dxe_test_mktemp_dir only; this shell never records a case.
# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# The probes must start as fresh suites, whatever ran this file.
unset DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER

HR_LIB_HELPERS="$SCRIPT_DIR/test_helpers.sh"
HR_LIB_HARNESS="$SCRIPT_DIR/lib/harness.sh"
HR_BASH="${BASH:-bash}"
HR_BOUND=120
HR_ESC="$(printf '\033')"
HR_FAIL_MARK="✗ FAIL"
HR_PASS_MARK="✓ PASS"
HR_FAILED_HEADER="Failed cases (from the results file):"

HR_DIR="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir HR_DIR "${TMPDIR:-/tmp}/dxe-harness-results-subshell.XXXXXX"
trap 'rm -rf "$HR_DIR"' EXIT
mkdir "$HR_DIR/probes" || exit 1

# --- grading vocabulary --------------------------------------------------

hr_passes=0
hr_failures=0
HR_NAME=""
HR_OUT=""
HR_STATUS=0
HR_TMP=""
HR_SHOWN=""

# hr_check DESCRIPTION CMD [ARGS...] -- one graded check of the current probe.
hr_check() {
    local what="$1"
    shift
    if "$@"; then
        hr_passes=$((hr_passes + 1))
        printf '  PASS: %s: %s\n' "$HR_NAME" "$what"
    else
        hr_failures=$((hr_failures + 1))
        printf '  FAIL: %s: %s\n' "$HR_NAME" "$what"
        if [ "$HR_SHOWN" != "$HR_NAME" ]; then
            HR_SHOWN="$HR_NAME"
            printf '    probe exit status: %s\n    probe output:\n' "$HR_STATUS"
            printf '%s\n' "$HR_OUT" | sed 's/^/      | /'
            printf '    left in its TMPDIR:\n'
            hr_listing "$HR_TMP" | sed 's/^/      | /'
        fi
    fi
}

# hr_case NAME -- starts a case: a fresh, empty TMPDIR for its probe(s).
hr_case() {
    HR_NAME="$1"
    HR_TMP="$HR_DIR/tmp-$1"
    mkdir "$HR_TMP" || exit 1
    echo ""
    echo "=== $1 ==="
}

# hr_probe NAME LIB BODY -- writes probe file $HR_DIR/probes/NAME.sh: a
# suite that sources LIB and runs BODY.
hr_probe() {
    {
        printf '#!/bin/bash\nset -uo pipefail\n'
        printf 'source %q\n' "$2"
        printf '%s\n' "$3"
    } > "$HR_DIR/probes/$1.sh" || exit 1
}

# hr_run [ENV-ARGS...] -- CMD... : runs CMD from $HR_DIR with TMPDIR=$HR_TMP
# (plus `env` arguments before `--`), bounded; sets HR_OUT (stdout+stderr,
# colour codes stripped) and HR_STATUS.
hr_run() {
    local envargs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        envargs+=("$1")
        shift
    done
    shift
    HR_OUT="$(cd "$HR_DIR" && env "${envargs[@]+"${envargs[@]}"}" TMPDIR="$HR_TMP" perl -e 'alarm shift; exec @ARGV' "$HR_BOUND" "$@" 2>&1)" && HR_STATUS=0 || HR_STATUS=$?
    HR_OUT="$(printf '%s\n' "$HR_OUT" | sed "s/${HR_ESC}\[[0-9;]*m//g")"
}

# hr_run_probe NAME [ENV-ARGS...] -- runs probe NAME with this file's bash.
hr_run_probe() {
    local name="$1"
    shift
    hr_run "$@" -- "$HR_BASH" "$HR_DIR/probes/$name.sh"
}

# hr_listing DIR -- every path under DIR, relative, sorted.
hr_listing() {
    (cd -P -- "$1" && find . -mindepth 1 -print) | LC_ALL=C sort
}

# hr_lines_equal LINE -- how many lines of HR_OUT are exactly LINE.
hr_lines_equal() {
    local line n=0
    while IFS= read -r line; do
        [ "$line" = "$1" ] && n=$((n + 1))
    done <<< "$HR_OUT"
    printf '%s' "$n"
}

# hr_results_lines -- every "Results: ..." line of HR_OUT, in order.
hr_results_lines() {
    local line
    while IFS= read -r line; do
        case "$line" in
            "Results: "*) printf '%s\n' "$line" ;;
        esac
    done <<< "$HR_OUT"
}

# hr_failed_list -- the entries of print_summary's "Failed cases" list(s).
hr_failed_list() {
    local line inlist=no
    while IFS= read -r line; do
        if [ "$line" = "$HR_FAILED_HEADER" ]; then
            inlist=yes
            continue
        fi
        if [ "$inlist" = yes ]; then
            case "$line" in
                "  $HR_FAIL_MARK: "*) printf '%s\n' "${line#"  $HR_FAIL_MARK: "}" ;;
                *) inlist=no ;;
            esac
        fi
    done <<< "$HR_OUT"
}

# Predicates over the current probe.
status_is() { [ "$HR_STATUS" -eq "$1" ]; }
status_nonzero() { [ "$HR_STATUS" -ne 0 ]; }
has_line() { [ "$(hr_lines_equal "$1")" -ge 1 ]; }
line_count_is() { [ "$(hr_lines_equal "$2")" -eq "$1" ]; }
only_results_line_is() { [ "$(hr_results_lines)" = "$1" ]; }
last_results_line_is() { [ "$(hr_results_lines | tail -n 1)" = "$1" ]; }
first_results_line_is() { [ "$(hr_results_lines | head -n 1)" = "$1" ]; }
no_results_line() { [ -z "$(hr_results_lines)" ]; }
# The list's entries as a set: one line each, order not pinned.
failed_list_is() { [ "$(hr_failed_list | LC_ALL=C sort)" = "$(printf '%s' "$1" | LC_ALL=C sort)" ]; }
out_contains() {
    case "$HR_OUT" in
        *"$1"*) return 0 ;;
        *) return 1 ;;
    esac
}
out_lacks() { ! out_contains "$1"; }
tmpdir_is_empty() { [ -z "$(hr_listing "$HR_TMP")" ]; }
tmpdir_listing_is() { [ "$(hr_listing "$HR_TMP")" = "$1" ]; }

# hr_expect_summary STATUS RESULTS FAILED-LIST -- the common shape: exact exit
# status, exactly one summary line, the failed list (newline-separated
# labels, "" for none), and an empty TMPDIR afterwards.
hr_expect_summary() {
    hr_check "exits $1" status_is "$1"
    hr_check "summary is exactly [$2]" only_results_line_is "$2"
    hr_check "failed-case list is exactly [$(printf '%s' "$3" | tr '\n' ',')]" failed_list_is "$3"
    hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty
}

# =========================================================================
# 1. First records from `( … )` subshells
# =========================================================================

# --- A. test_helpers.sh suite: three subshell records, one failing, nothing
# at the top level before print_summary.
hr_case A-subshell-first-with-failure
hr_probe A "$HR_LIB_HELPERS" '
( test_pass "sub-a" )
( test_fail "sub-b" )
( test_pass "sub-c" )
print_summary
exit_with_code'
hr_run_probe A
hr_expect_summary 1 "Results: 2 passed, 1 failed, 0 skipped" "sub-b"
hr_check "the failure shows live and in the failed-case list" line_count_is 2 "  $HR_FAIL_MARK: sub-b"

# --- B. the same, every case passing: counted, and still exit 0.
hr_case B-subshell-first-all-pass
hr_probe B "$HR_LIB_HELPERS" '
( test_pass "only-a" )
( test_pass "only-b" )
print_summary
exit_with_code'
hr_run_probe B
hr_expect_summary 0 "Results: 2 passed, 0 failed, 0 skipped" ""

# --- C. harness-native suite (expect_* + finish): a subshell failure is a
# failure (exit 1), not "zero cases" (exit 3).
hr_case C-native-subshell-first-with-failure
hr_probe C "$HR_LIB_HARNESS" '
( expect_exit 0 true )
( expect_exit 0 false )
finish'
hr_run_probe C
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 1 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# --- D. harness-native, a pass and a classed skip, both from subshells.
hr_case D-native-subshell-first-pass-and-skip
hr_probe D "$HR_LIB_HARNESS" '
( expect_exit 0 true )
( skip --class live "native-sub-skip" )
finish'
hr_run_probe D
hr_check "exits 0" status_is 0
hr_check "summary is exactly [Results: 1 passed, 0 failed, 1 skipped]" only_results_line_is "Results: 1 passed, 0 failed, 1 skipped"
hr_check "prints [Skipped classes: live=1]" has_line "Skipped classes: live=1"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# 2. First records from `$( … )` command substitutions
# =========================================================================

# --- E. test_helpers.sh suite.
hr_case E-command-substitution-first
hr_probe E "$HR_LIB_HELPERS" '
cs_fail_out="$(test_fail "cs-fail")"
cs_pass_out="$(test_pass "cs-pass")"
printf "captured: %s | %s\n" "$cs_fail_out" "$cs_pass_out"
print_summary
exit_with_code'
hr_run_probe E
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "cs-fail"

# --- F. harness-native suite: the expect_* report captured, the case kept.
hr_case F-native-command-substitution-first
hr_probe F "$HR_LIB_HARNESS" '
cs_report="$(expect_exit 0 false)"
printf "captured: %s\n" "$cs_report"
finish'
hr_run_probe F
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 0 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 0 passed, 1 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# 3. First records from background jobs that are waited for
# =========================================================================

# --- G. test_helpers.sh suite: seven concurrent jobs race to record first
# (a subshell job and six function jobs); every case counted once.
hr_case G-background-jobs-first
hr_probe G "$HR_LIB_HELPERS" '
( test_fail "bg-fail" ) &
for bg_n in 1 2 3 4 5 6; do
    test_pass "bg-pass-$bg_n" &
done
wait
print_summary
exit_with_code'
hr_run_probe G
hr_expect_summary 1 "Results: 6 passed, 1 failed, 0 skipped" "bg-fail"

# --- H. harness-native suite: a skip job and an expect_exit job.
hr_case H-native-background-jobs-first
hr_probe H "$HR_LIB_HARNESS" '
skip --class destructive "bg-native-skip" &
( expect_exit 0 true ) &
wait
finish'
hr_run_probe H
hr_check "exits 0" status_is 0
hr_check "summary is exactly [Results: 1 passed, 0 failed, 1 skipped]" only_results_line_is "Results: 1 passed, 0 failed, 1 skipped"
hr_check "prints [Skipped classes: destructive=1]" has_line "Skipped classes: destructive=1"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# 4. Mixed order: fork, top level, fork, ... -- each case exactly once
# =========================================================================

hr_case I-mixed-order
hr_probe I "$HR_LIB_HELPERS" '
test_section "mixed"
( test_pass "m-sub-1" )
test_pass "m-top-1"
( test_fail "m-sub-2" )
test_fail "m-top-2"
m_cs="$(test_pass "m-cs-1")"
( test_skip "m-sub-skip" )
test_pass "m-bg-1" &
wait
( test_fail "m-sub-3" )
print_summary
exit_with_code'
hr_run_probe I
hr_expect_summary 1 "Results: 4 passed, 3 failed, 1 skipped" "m-sub-2
m-top-2
m-sub-3"

# =========================================================================
# 5. Isolation: foreign files and nested suites
# =========================================================================

# --- J. Probe A again, with a foreign results file in its TMPDIR, inherited
# as DXE_TEST_RESULTS with an owner that is not the probe (pid 1). Neither
# its records nor the file itself may be counted, written or removed.
hr_case J-foreign-results-file
J_FOREIGN="$HR_TMP/dxe-harness-results.foreign"
printf 'fail\tforeign-stale-fail\npass\tforeign-stale-pass\n' > "$J_FOREIGN"
J_FOREIGN_BEFORE="$(cat "$J_FOREIGN")"
hr_run_probe A DXE_TEST_RESULTS="$J_FOREIGN" DXE_TEST_RESULTS_OWNER=1
j_foreign_unchanged() { [ -f "$J_FOREIGN" ] && [ "$(cat "$J_FOREIGN")" = "$J_FOREIGN_BEFORE" ]; }
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 2 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 2 passed, 1 failed, 0 skipped"
hr_check "failed-case list is exactly [sub-b]" failed_list_is "sub-b"
hr_check "the foreign file is left exactly as it was" j_foreign_unchanged
hr_check "leaves nothing but the foreign file in its TMPDIR" tmpdir_listing_is "./dxe-harness-results.foreign"

# --- K. A parent whose first record is a subshell failure runs a complete
# child suite (`bash FILE`, two passes, one of them in a subshell), then
# records at its top level. Each counts only its own cases.
hr_case K-nested-suite-after-forked-first-record
hr_probe K-child "$HR_LIB_HELPERS" '
test_pass "child-top-pass"
( test_pass "child-sub-pass" )
print_summary
exit_with_code'
hr_probe K "$HR_LIB_HELPERS" '
( test_fail "parent-sub-fail" )
"${BASH:-bash}" "$HR_CHILD"
echo "child_status=$?"
test_pass "parent-top-pass"
print_summary
exit_with_code'
hr_run_probe K HR_CHILD="$HR_DIR/probes/K-child.sh"
hr_check "the child reports only its own cases" first_results_line_is "Results: 2 passed, 0 failed, 0 skipped"
hr_check "the child exits 0" has_line "child_status=0"
hr_check "the parent reports only its own cases" last_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "the parent's failed-case list is exactly [parent-sub-fail]" failed_list_is "parent-sub-fail"
hr_check "the parent exits 1" status_is 1
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# --- L. A parent that records at its top level first (its DXE_TEST_RESULTS
# exported) runs a child suite whose first record is a subshell failure,
# then records again in a subshell. The child neither appends to nor removes
# the parent's file; its own failure fails the child, not the parent.
hr_case L-nested-suite-with-forked-failure
hr_probe L-child "$HR_LIB_HELPERS" '
( test_fail "child-sub-fail" )
test_pass "child-top-pass"
print_summary
exit_with_code'
hr_probe L "$HR_LIB_HELPERS" '
test_pass "parent-top-pass"
"${BASH:-bash}" "$HR_CHILD"
echo "child_status=$?"
( test_pass "parent-sub-pass-after-child" )
print_summary
exit_with_code'
hr_run_probe L HR_CHILD="$HR_DIR/probes/L-child.sh"
hr_check "the child reports only its own cases" first_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "the child exits 1" has_line "child_status=1"
hr_check "the parent reports only its own cases" last_results_line_is "Results: 2 passed, 0 failed, 0 skipped"
hr_check "the parent exits 0" status_is 0
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# 6. Lazy creation: sourcing alone, and the runner
# =========================================================================

# The child sources nothing: only what it inherited is under test.
# shellcheck disable=SC2016 # program text for the probe, expanded there
printf '#!/bin/bash\n%s\n' 'echo "child_saw=[${DXE_TEST_RESULTS-}][${DXE_TEST_RESULTS_OWNER-}]"' > "$HR_DIR/probes/M-child.sh" || exit 1
M_SOURCE_ONLY_BODY='
echo "var=[${DXE_TEST_RESULTS-}]"
if printenv DXE_TEST_RESULTS >/dev/null; then echo "exported=yes"; else echo "exported=no"; fi
if printenv DXE_TEST_RESULTS_OWNER >/dev/null; then echo "owner_exported=yes"; else echo "owner_exported=no"; fi
"${BASH:-bash}" "$HR_CHILD"'
for m_lib in harness test_helpers; do
    hr_case "M-source-only-$m_lib"
    if [ "$m_lib" = harness ]; then
        hr_probe "M-$m_lib" "$HR_LIB_HARNESS" "$M_SOURCE_ONLY_BODY"
    else
        hr_probe "M-$m_lib" "$HR_LIB_HELPERS" "$M_SOURCE_ONLY_BODY"
    fi
    hr_run_probe "M-$m_lib" HR_CHILD="$HR_DIR/probes/M-child.sh"
    hr_check "exits 0" status_is 0
    hr_check "DXE_TEST_RESULTS is empty" has_line "var=[]"
    hr_check "DXE_TEST_RESULTS is not exported" has_line "exported=no"
    hr_check "DXE_TEST_RESULTS_OWNER is not exported" has_line "owner_exported=no"
    hr_check "a child started after sourcing inherits neither" has_line "child_saw=[][]"
    hr_check "creates nothing in its TMPDIR" tmpdir_is_empty
done

# --- N. tests/run.sh --file: the suite starts with no results variables,
# and its forked failure fails the run.
hr_case N-runner
{
    printf '#!/bin/bash\n# %s: unit\n# %s: yes\nset -uo pipefail\n' tier bash32
    printf '%s\n' 'echo "inherited=[${DXE_TEST_RESULTS-}][${DXE_TEST_RESULTS_OWNER-}]"'
    printf 'source %q\n' "$HR_LIB_HELPERS"
    printf '%s\n' '( test_fail "runner-sub-fail" )' 'test_pass "runner-top-pass"' 'print_summary' 'exit_with_code'
} > "$HR_DIR/probes/hr-runner.sh" || exit 1
hr_run SKIP_INTEGRATION=true -- "$HR_BASH" "$SCRIPT_DIR/run.sh" --file "$HR_DIR/probes/hr-runner.sh"
hr_check "the suite inherits no results variables from the runner" has_line "inherited=[][]"
hr_check "the suite reports its forked failure" only_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "the runner marks the suite failed" has_line "FAIL: hr-runner.sh failed."
hr_check "the runner reports [Some tests FAILED.]" has_line "Some tests FAILED."
hr_check "the runner exits 1" status_is 1
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# 7. Fail-closed: a results file that cannot be created
# =========================================================================

# A decoy copy of the harness, run from inside this file's scratch directory
# with a TMPDIR that does not exist there.
mkdir "$HR_DIR/decoy" "$HR_DIR/decoy/tests" || exit 1
cp "$SCRIPT_DIR/test_helpers.sh" "$HR_DIR/decoy/tests/test_helpers.sh" || exit 1
cp -R "$SCRIPT_DIR/lib" "$HR_DIR/decoy/tests/lib" || exit 1
hr_probe O-helpers "$HR_DIR/decoy/tests/test_helpers.sh" '
( test_pass "fc-sub-pass" )
( test_fail "fc-sub-fail" )
fc_cs="$(test_pass "fc-cs-pass")"
print_summary
exit_with_code
echo "@@continued@@"'
hr_probe O-native "$HR_DIR/decoy/tests/lib/harness.sh" '
( skip --class live "fc-native-skip" )
finish
echo "@@continued@@"'
for o_lib in helpers native; do
    hr_case "O-fail-closed-$o_lib"
    HR_TMP="$HR_DIR/tmp-O-$o_lib-missing"
    hr_run -u DXE_CONFIG_RESOLVED -- "$HR_BASH" "$HR_DIR/probes/O-$o_lib.sh"
    HR_TMP="$HR_DIR/tmp-O-fail-closed-$o_lib"
    o_missing_absent() { [ ! -e "$HR_DIR/tmp-O-$o_lib-missing" ]; }
    hr_check "exits non-zero" status_nonzero
    hr_check "names the results file" out_contains "results file"
    hr_check "prints no summary" no_results_line
    hr_check "prints no case result line" out_lacks "$HR_PASS_MARK"
    hr_check "prints no failure result line" out_lacks "$HR_FAIL_MARK"
    hr_check "stops before the code after the summary" out_lacks "@@continued@@"
    hr_check "creates no TMPDIR" o_missing_absent
done

echo ""
echo "=============================="
echo "Results: $hr_passes passed, $hr_failures failed, 0 skipped"
echo "=============================="
[ "$hr_failures" -eq 0 ]
