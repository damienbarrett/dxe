#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
set -uo pipefail

# tests/test_harness_results_b.sh -- Red for WP-HARNESS-RES-b, the follow-up to
# the results-file fix (main d60608d). Locked sibling: tests/test_harness_results_subshell.sh.
#
# Interface contract (WP-HARNESS-RES-b):
#
#  F5. The harness's housekeeping never goes through the suite's PATH or its
#      shell functions. A suite that puts RECORDING stubs for rm, find, chmod,
#      chown, mv and ln first on PATH (or defines shell functions of those
#      names) AFTER sourcing the harness but BEFORE its first test_pass /
#      test_fail / skip / expect_* must find nothing the harness ran in its
#      stub log: not for the first record, not for later records, not for
#      expect_exit/expect_stdout/expect_stderr's capture files, not for
#      with_fixture's known-hosts snapshot, not for print_summary /
#      exit_with_code / finish. The stubs here only RECORD (they delete and
#      link nothing), so the counts being right and no results/capture file
#      being left behind prove the harness did its own cleanup and linking
#      with the real tools. mktemp stays a seam: it is still the mktemp found
#      on PATH (a recording mktemp wrapper on PATH sees the harness's calls),
#      so a failing mktemp, or a TMPDIR that does not exist, still stops the
#      suite non-zero with the words "results file" and no summary.
#  F1. A fork (subshell, command substitution or background job) that unsets
#      DXE_TEST_RESULTS (and optionally DXE_TEST_RESULTS_OWNER) and calls
#      exit_with_code or finish neither deletes the suite's results file nor
#      hides a parent FAIL: the parent's later summary counts every record
#      and exits 1. (What the fork itself prints or exits with is not pinned.)
#  F2. The directory holding the results file is fixed when the harness is
#      sourced: TMPDIR changed later (with_fixture does) or in a fork loses
#      no record, and nothing is left in either directory.
#  F3. Re-sourcing the harness in a fork, or again in the parent, loses no
#      record; 50 background jobs recording at once are counted exactly; with
#      a failing `ln` first on PATH the suite either completes with the right
#      counts (the harness did not use that ln) or stops non-zero ("results
#      file", no summary) -- never a miscount or a silent success.
#  F4. The agreed results path is ${TMPDIR:-/tmp}/dxe-harness-results.$DXE_HARNESS_RES_TOKEN
#      (the token variable, set when the harness is sourced, is part of the
#      contract). If that path is a symlink -- to a file, dangling, or to a
#      directory -- the first record stops the suite non-zero with a message
#      containing the words "results file" and "symlink", prints no summary,
#      and writes through nothing. A failing `ln`'s own stderr is kept: when
#      the harness stops because of it, that text is in the output.
#      Not pinned: a foreign-owned agreed file (needs a second user to
#      create; an unprivileged test cannot).
#
# Grading is by this file's own small vocabulary (as in the sibling), every
# probe is a FILE run with bash as its own suite process with its own empty
# TMPDIR. Safety: the stubs only record; the one broken TMPDIR / failing-mktemp
# case runs a DECOY copy of the harness; no probe runs a destructive command.

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
dxe_test_mktemp_dir HR_DIR "${TMPDIR:-/tmp}/dxe-harness-results-b.XXXXXX"
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


# --- extra vocabulary for this file ---------------------------------------

# hr_body VAR -- reads a probe body from a here-document into VAR.
hr_body() {
    IFS= read -r -d '' "$1" || true
}

# hr_stubs N -- recording stubs for the destructive commands, in
# $HR_DIR/stubs-N, logging to $HR_DIR/log-N (both OUTSIDE the probe's TMPDIR).
# They record and do nothing else: nothing can be deleted, linked or moved.
F5_STUBS=""
F5_LOG=""
hr_stubs() {
    local t
    F5_STUBS="$HR_DIR/stubs-$1"
    F5_LOG="$HR_DIR/log-$1"
    mkdir "$F5_STUBS" || exit 1
    : > "$F5_LOG" || exit 1
    for t in rm find chmod chown mv ln; do
        printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$t" "$F5_LOG" > "$F5_STUBS/$t" || exit 1
        chmod 0755 "$F5_STUBS/$t" || exit 1
    done
}

log_empty() { [ ! -s "$F5_LOG" ]; }
log_not_empty() { [ -s "$F5_LOG" ]; }
# No harness-made file anywhere under the probe's TMPDIR (a suite's own
# fixture directories may remain).
no_harness_files() {
    local listing
    listing="$(hr_listing "$HR_TMP")"
    case "$listing" in
        *dxe-harness-results*|*dxe-harness-out*|*dxe-harness-err*) return 1 ;;
    esac
    return 0
}
other_dir_is_empty() { [ -z "$(hr_listing "$HR_OTHER")" ]; }

# Every probe ends by showing the stub log, so a failure explains itself.
F5_TRAP='trap '"'"'printf "@@stub-log\n"; cat "$F5_LOG"; printf "@@end\n"'"'"' EXIT'

# =========================================================================
# F5. housekeeping bypasses the suite's PATH stubs and shell functions
# =========================================================================

# --- F5-a. test_helpers.sh suite; first record is test_pass under stubs.
hr_case F5-a-helpers-stubs-first
hr_stubs a
hr_body body <<'EOP'
PATH="$F5_STUBS:$PATH"
test_pass "f5a-1"
test_fail "f5a-2"
( test_pass "f5a-3" )
cs="$(test_pass "f5a-4")"
print_summary
exit_with_code
EOP
hr_probe F5a "$HR_LIB_HELPERS" "$F5_TRAP
$body"
hr_run_probe F5a F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG"
hr_expect_summary 1 "Results: 3 passed, 1 failed, 0 skipped" "f5a-2"
hr_check "no harness-internal command reached the stub log" log_empty

# --- F5-b. native suite; first record is expect_exit (capture files), then
# its siblings, a skip and finish.
hr_case F5-b-native-expect-stubs-first
hr_stubs b
hr_body body <<'EOP'
PATH="$F5_STUBS:$PATH"
it "f5b exit pass"; expect_exit 0 true
it "f5b exit fail"; expect_exit 1 true
it "f5b stdout pass"; expect_stdout '^hi$' echo hi
it "f5b stderr fail"; expect_stderr 'never-printed' true
printf 'x\n' > "$F5_FILE"
it "f5b file eq"; expect_file_eq "$F5_FILE" "x"
skip --class live "f5b skip"
finish
EOP
hr_probe F5b "$HR_LIB_HARNESS" "$F5_TRAP
$body"
hr_run_probe F5b F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG" F5_FILE="$HR_DIR/f5b.file"
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 3 passed, 2 failed, 1 skipped]" only_results_line_is "Results: 3 passed, 2 failed, 1 skipped"
hr_check "prints [Skipped classes: live=1]" has_line "Skipped classes: live=1"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty
hr_check "no harness-internal command reached the stub log" log_empty

# --- F5-c. native suite; the first record is a skip, then with_fixture (its
# known-hosts snapshot runs `find` on a real tree) and finish.
hr_case F5-c-native-skip-first-with-fixture
hr_stubs c
mkdir -p "$HR_DIR/home-c/.local/state/dxe" || exit 1
: > "$HR_DIR/home-c/.local/state/dxe/known" || exit 1
hr_body body <<'EOP'
PATH="$F5_STUBS:$PATH"
skip --class live "f5c skip"
with_fixture
it "f5c exit"; expect_exit 0 true
it "f5c exit fail"; expect_exit 2 false
finish
EOP
hr_probe F5c "$HR_LIB_HARNESS" "$F5_TRAP
$body"
hr_run_probe F5c -u XDG_STATE_HOME HOME="$HR_DIR/home-c" F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG"
hr_check "exits 1 (one case fails on purpose: false is exit 1, not 2)" status_is 1
hr_check "summary is exactly [Results: 1 passed, 1 failed, 1 skipped]" only_results_line_is "Results: 1 passed, 1 failed, 1 skipped"
hr_check "leaves no harness file in its TMPDIR" no_harness_files
hr_check "no harness-internal command reached the stub log" log_empty

# --- F5-d / F5-e. the same through SHELL FUNCTIONS named rm/ln/find/..., which
# also shadow `command`-less calls.
hr_case F5-d-native-function-shadows
hr_stubs d
hr_body body <<'EOP'
for f in rm ln find chmod chown mv; do
    eval "$f() { echo \"$f \$*\" >> \"\$F5_LOG\"; }"
done
it "f5d exit"; expect_exit 0 true
with_fixture
it "f5d stdout"; expect_stdout 'nope' echo hi
finish
EOP
hr_probe F5d "$HR_LIB_HARNESS" "$F5_TRAP
$body"
hr_run_probe F5d -u XDG_STATE_HOME HOME="$HR_DIR/home-c" F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG"
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 1 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "leaves no harness file in its TMPDIR" no_harness_files
hr_check "no harness-internal command reached the function log" log_empty

hr_case F5-e-helpers-function-shadows
hr_stubs e
hr_body body <<'EOP'
for f in rm ln find chmod chown mv; do
    eval "$f() { echo \"$f \$*\" >> \"\$F5_LOG\"; }"
done
test_fail "f5e-1"
test_pass "f5e-2"
print_summary
exit_with_code
EOP
hr_probe F5e "$HR_LIB_HELPERS" "$F5_TRAP
$body"
hr_run_probe F5e F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG"
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "f5e-1"
hr_check "no harness-internal command reached the function log" log_empty

# --- F5-f. mktemp stays a seam: a recording mktemp wrapper on PATH, after the
# rm/ln/... stubs, still sees the harness's calls.
hr_case F5-f-mktemp-seam-kept
hr_stubs f
F5_MKLOG="$HR_DIR/mklog-f"
: > "$F5_MKLOG" || exit 1
F5_REAL_MKTEMP="$(command -v mktemp)"
printf '#!/bin/bash\necho "mktemp $*" >> "%s"\nexec "%s" "$@"\n' "$F5_MKLOG" "$F5_REAL_MKTEMP" > "$F5_STUBS/mktemp" || exit 1
chmod 0755 "$F5_STUBS/mktemp" || exit 1
hr_body body <<'EOP'
PATH="$F5_STUBS:$PATH"
test_pass "f5f-1"
it "f5f exit"; expect_exit 0 true
print_summary
exit_with_code
EOP
hr_probe F5f "$HR_LIB_HELPERS" "$F5_TRAP
$body"
hr_run_probe F5f F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG"
hr_expect_summary 0 "Results: 2 passed, 0 failed, 0 skipped" ""
hr_check "no harness-internal command reached the stub log" log_empty
f5f_mktemp_seen() { [ -s "$F5_MKLOG" ]; }
hr_check "the harness still called the mktemp found on PATH" f5f_mktemp_seen

# --- F5-g / F5-h. housekeeping stays fail-closed with the stubs in place: a
# failing mktemp on PATH, and a TMPDIR that does not exist. Both run a DECOY
# copy of the harness from this file's scratch directory.
mkdir "$HR_DIR/decoy" "$HR_DIR/decoy/tests" || exit 1
cp "$SCRIPT_DIR/test_helpers.sh" "$HR_DIR/decoy/tests/test_helpers.sh" || exit 1
cp -R "$SCRIPT_DIR/lib" "$HR_DIR/decoy/tests/lib" || exit 1

hr_case F5-g-failing-mktemp-fails-closed
hr_stubs g
printf '#!/bin/bash\necho "mktemp $*" >> "%s"\nexit 1\n' "$HR_DIR/mklog-g" > "$F5_STUBS/mktemp" || exit 1
chmod 0755 "$F5_STUBS/mktemp" || exit 1
hr_body body <<'EOP'
PATH="$F5_STUBS:$PATH"
test_pass "f5g-1"
print_summary
exit_with_code
echo "@@continued@@"
EOP
hr_probe F5g "$HR_DIR/decoy/tests/test_helpers.sh" "$F5_TRAP
$body"
hr_run_probe F5g F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG"
hr_check "exits non-zero" status_nonzero
hr_check "names the results file" out_contains "results file"
hr_check "prints no summary" no_results_line
hr_check "prints no case result line" out_lacks "$HR_PASS_MARK"
hr_check "stops before the code after the summary" out_lacks "@@continued@@"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty
hr_check "no harness-internal command reached the stub log" log_empty

hr_case F5-h-missing-tmpdir-fails-closed
hr_stubs h
hr_body body <<'EOP'
PATH="$F5_STUBS:$PATH"
( test_pass "f5h-1" )
finish
echo "@@continued@@"
EOP
hr_probe F5h "$HR_DIR/decoy/tests/lib/harness.sh" "$F5_TRAP
$body"
HR_TMP="$HR_DIR/tmp-F5-h-missing"
hr_run -- env F5_STUBS="$F5_STUBS" F5_LOG="$F5_LOG" "$HR_BASH" "$HR_DIR/probes/F5h.sh"
f5h_absent() { [ ! -e "$HR_TMP" ]; }
hr_check "exits non-zero" status_nonzero
hr_check "names the results file" out_contains "results file"
hr_check "prints no summary" no_results_line
hr_check "stops before the code after finish" out_lacks "@@continued@@"
hr_check "creates no TMPDIR" f5h_absent
hr_check "no harness-internal command reached the stub log" log_empty

# =========================================================================
# F1. a fork that unsets DXE_TEST_RESULTS and ends the suite
# =========================================================================

hr_case F1-a-helpers-fork-exit-with-code
hr_body body <<'EOP'
test_fail "f1a-parent-fail"
test_pass "f1a-parent-pass"
( unset DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER; exit_with_code ) 2>/dev/null
test_pass "f1a-after-fork"
print_summary
exit_with_code
EOP
hr_probe F1a "$HR_LIB_HELPERS" "$body"
hr_run_probe F1a
hr_expect_summary 1 "Results: 2 passed, 1 failed, 0 skipped" "f1a-parent-fail"

hr_case F1-b-helpers-substitution-unset-path-only
hr_body body <<'EOP'
test_fail "f1b-parent-fail"
x="$(unset DXE_TEST_RESULTS; exit_with_code)" 2>/dev/null
test_pass "f1b-after-fork"
print_summary
exit_with_code
EOP
hr_probe F1b "$HR_LIB_HELPERS" "$body"
hr_run_probe F1b
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "f1b-parent-fail"

hr_case F1-c-native-background-fork-finish
hr_body body <<'EOP'
it "f1c fails"; expect_exit 1 true
it "f1c passes"; expect_exit 0 true
( unset DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER; finish ) >/dev/null 2>&1 &
wait
it "f1c after"; expect_exit 0 true
finish
EOP
hr_probe F1c "$HR_LIB_HARNESS" "$body"
hr_run_probe F1c
hr_check "exits 1" status_is 1
hr_check "the last summary is exactly [Results: 2 passed, 1 failed, 0 skipped]" last_results_line_is "Results: 2 passed, 1 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# F2. TMPDIR changing between a fork's first record and the parent's
# =========================================================================

HR_OTHER=""
hr_other() {
    HR_OTHER="$HR_DIR/other-$1"
    mkdir "$HR_OTHER" || exit 1
}

hr_case F2-a-parent-changes-tmpdir
hr_other a
hr_body body <<'EOP'
( test_pass "f2a-fork-1" )
( test_fail "f2a-fork-2" )
TMPDIR="$F2_OTHER"; export TMPDIR
test_pass "f2a-parent-1"
print_summary
exit_with_code
EOP
hr_probe F2a "$HR_LIB_HELPERS" "$body"
hr_run_probe F2a F2_OTHER="$HR_OTHER"
hr_expect_summary 1 "Results: 2 passed, 1 failed, 0 skipped" "f2a-fork-2"
hr_check "leaves nothing in the other directory" other_dir_is_empty

hr_case F2-b-fork-changes-tmpdir
hr_other b
hr_body body <<'EOP'
( TMPDIR="$F2_OTHER"; test_fail "f2b-fork-in-other" )
test_pass "f2b-parent"
print_summary
exit_with_code
EOP
hr_probe F2b "$HR_LIB_HELPERS" "$body"
hr_run_probe F2b F2_OTHER="$HR_OTHER"
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "f2b-fork-in-other"
hr_check "leaves nothing in the other directory" other_dir_is_empty

hr_case F2-c-with-fixture-after-fork-record
hr_body body <<'EOP'
( it "f2c fork"; expect_exit 0 true )
with_fixture
it "f2c parent fails"; expect_exit 1 true
it "f2c parent passes"; expect_exit 0 true
finish
EOP
hr_probe F2c "$HR_LIB_HARNESS" "$body"
hr_run_probe F2c -u XDG_STATE_HOME HOME="$HR_DIR/home-c"
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 2 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 2 passed, 1 failed, 0 skipped"
hr_check "leaves no harness file in its TMPDIR" no_harness_files

# =========================================================================
# F3. re-sourcing, a 50-job race, a failing ln
# =========================================================================

hr_case F3-a-resource-in-fork-and-parent
hr_body body <<'EOP'
( source "$F3_LIB"; test_fail "f3a-fork-first" )
test_pass "f3a-top"
source "$F3_LIB"
test_pass "f3a-top-resourced"
( source "$F3_LIB"; test_pass "f3a-fork-last" )
print_summary
exit_with_code
EOP
hr_probe F3a "$HR_LIB_HELPERS" "$body"
hr_run_probe F3a F3_LIB="$HR_LIB_HELPERS"
hr_expect_summary 1 "Results: 3 passed, 1 failed, 0 skipped" "f3a-fork-first"

hr_case F3-b-resource-native-in-fork
hr_body body <<'EOP'
( source "$F3_LIB"; it "f3b fork"; expect_exit 1 true )
it "f3b top"; expect_exit 0 true
finish
EOP
hr_probe F3b "$HR_LIB_HARNESS" "$body"
hr_run_probe F3b F3_LIB="$HR_LIB_HARNESS"
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 1 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

hr_case F3-c-fifty-job-race-helpers
hr_body body <<'EOP'
i=0
while [ "$i" -lt 50 ]; do
    i=$((i + 1))
    if [ $((i % 5)) -eq 0 ]; then
        test_fail "race-$i" > /dev/null &
    else
        test_pass "race-$i" > /dev/null &
    fi
done
wait
print_summary
exit_with_code
EOP
hr_probe F3c "$HR_LIB_HELPERS" "$body"
hr_run_probe F3c
f3c_expected="$(i=0; while [ "$i" -lt 50 ]; do i=$((i + 1)); [ $((i % 5)) -eq 0 ] && printf 'race-%s\n' "$i"; done)"
hr_expect_summary 1 "Results: 40 passed, 10 failed, 0 skipped" "$f3c_expected"

hr_case F3-d-fifty-job-race-native
hr_body body <<'EOP'
i=0
while [ "$i" -lt 50 ]; do
    i=$((i + 1))
    if [ $((i % 5)) -eq 0 ]; then
        ( it "nrace-$i"; expect_exit 1 true ) > /dev/null &
    else
        ( it "nrace-$i"; expect_exit 0 true ) > /dev/null &
    fi
done
wait
finish
EOP
hr_probe F3d "$HR_LIB_HARNESS" "$body"
hr_run_probe F3d
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 40 passed, 10 failed, 0 skipped]" only_results_line_is "Results: 40 passed, 10 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# --- F3-e. a failing `ln` first on PATH (with a marker on its stderr): either
# the suite completes with exact counts, or it stops closed, saying why.
hr_case F3-e-failing-ln-never-miscounts
hr_stubs ln
printf '#!/bin/bash\necho "FAKE-LN-DIAG: refused" >&2\nexit 1\n' > "$F5_STUBS/ln" || exit 1
hr_body body <<'EOP'
PATH="$F5_STUBS:$PATH"
test_pass "f3e-1"
test_pass "f3e-2"
print_summary
exit_with_code
echo "@@continued@@"
EOP
hr_probe F3e "$HR_LIB_HELPERS" "$body"
hr_run_probe F3e F5_STUBS="$F5_STUBS"
f3e_completed() { [ "$HR_STATUS" -eq 0 ] && [ "$(hr_results_lines)" = "Results: 2 passed, 0 failed, 0 skipped" ]; }
f3e_stopped_closed() {
    [ "$HR_STATUS" -ne 0 ] && [ -z "$(hr_results_lines)" ] && out_contains "results file" \
        && out_contains "FAKE-LN-DIAG: refused" && out_lacks "@@continued@@"
}
f3e_either() { f3e_completed || f3e_stopped_closed; }
hr_check "completes with exact counts, or stops non-zero naming the results file and keeping ln's stderr" f3e_either
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# F4. a symlinked agreed results path is refused
# =========================================================================

# f4_case NAME LIB KIND -- plants a symlink of KIND at the agreed path before
# the first record.
f4_case() {
    local name="$1" lib="$2" kind="$3" target="$HR_DIR/f4-target-$1"
    hr_case "F4-$name"
    case "$kind" in
        file) : > "$target" || exit 1 ;;
        dir) mkdir "$target" || exit 1 ;;
        dangling) : ;;
    esac
    hr_body body <<'EOP'
ln -s "$F4_TARGET" "$TMPDIR/dxe-harness-results.$DXE_HARNESS_RES_TOKEN"
test_pass "f4-should-not-run"
print_summary
exit_with_code
echo "@@continued@@"
EOP
    if [ "$lib" = native ]; then
        body="${body//test_pass \"f4-should-not-run\"/it \"f4-should-not-run\"; expect_exit 0 true}"
        body="${body//print_summary/finish}"
        lib="$HR_LIB_HARNESS"
    else
        lib="$HR_LIB_HELPERS"
    fi
    hr_probe "F4$name" "$lib" "$body"
    hr_run_probe "F4$name" F4_TARGET="$target"
    hr_check "exits non-zero" status_nonzero
    hr_check "names the results file" out_contains "results file"
    hr_check "says it is a symlink" out_contains "symlink"
    hr_check "prints no summary" no_results_line
    hr_check "stops before the code after the summary" out_lacks "@@continued@@"
    case "$kind" in
        file) f4_untouched() { [ -f "$target" ] && [ ! -s "$target" ]; } ;;
        dir) f4_untouched() { [ -d "$target" ] && [ -z "$(hr_listing "$target")" ]; } ;;
        dangling) f4_untouched() { [ ! -e "$target" ] && [ ! -L "$target" ]; } ;;
    esac
    hr_check "wrote through nothing" f4_untouched
}
f4_case helpers-file helpers file
f4_case helpers-dangling helpers dangling
f4_case helpers-dir helpers dir
f4_case native-file native file
f4_case native-dangling native dangling

# --- F4-b. ln's own stderr is kept when the harness stops because `ln` failed
# for real: a FIFO already sits at the agreed path (neither a regular file nor
# a symlink), so the link cannot be made ("File exists" from ln, on macOS and
# GNU alike).
for f4b_lib in helpers native; do
    hr_case "F4-b-$f4b_lib-ln-failure-keeps-stderr"
    hr_body body <<'EOP'
mkfifo "$TMPDIR/dxe-harness-results.$DXE_HARNESS_RES_TOKEN" || exit 99
test_pass "f4b-should-not-run"
print_summary
exit_with_code
echo "@@continued@@"
EOP
    f4b_src="$HR_LIB_HELPERS"
    if [ "$f4b_lib" = native ]; then
        f4b_src="$HR_LIB_HARNESS"
        body="${body//test_pass \"f4b-should-not-run\"/it \"f4b-should-not-run\"; expect_exit 0 true}"
        body="${body//print_summary/finish}"
    fi
    hr_probe "F4b$f4b_lib" "$f4b_src" "$body"
    hr_run_probe "F4b$f4b_lib"
    hr_check "exits non-zero" status_nonzero
    hr_check "names the results file" out_contains "results file"
    hr_check "keeps ln's own message" out_contains "File exists"
    hr_check "prints no summary" no_results_line
    hr_check "stops before the code after the summary" out_lacks "@@continued@@"
done

echo ""
echo "=============================="
echo "Results: $hr_passes passed, $hr_failures failed, 0 skipped"
echo "=============================="
[ "$hr_failures" -eq 0 ]
