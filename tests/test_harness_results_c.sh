#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
set -uo pipefail

# tests/test_harness_results_c.sh -- Red for WP-TESTS-B3, harness round c: the
# probes that survived the WP-HARNESS-RES-b verifier (main 15eab2b), and the
# gaps they point at. Siblings: tests/test_harness_results_subshell.sh,
# tests/test_harness_results_b.sh (same grading vocabulary, same probe shape).
#
# Interface contract (WP-TESTS-B3):
#
#  C1. (M1) The suite's shell is the shell that SOURCED the harness, at
#      whatever subshell level that was: a harness sourced inside `( … )` (one
#      or two levels down) and ended there by exit_with_code / finish removes
#      its results file -- nothing is left in TMPDIR -- with exact counts.
#  C2. (M2) That level is fixed by the first source in the process: a fork that
#      sources the harness AGAIN and then ends itself with exit_with_code /
#      finish (with or without unsetting DXE_TEST_RESULTS[_OWNER]; subshell,
#      command substitution or background job) never deletes the suite's
#      results file: the parent's later summary counts every record.
#  C3. (M7) So is the results directory: TMPDIR changed (by hand or by
#      with_fixture) and the harness re-sourced in a fork that records FIRST
#      splits nothing -- exact counts, no results file left anywhere.
#  C4. (M4) rm, ln and find are the absolute paths found when the harness was
#      first sourced, and nothing else, ever: a tool that was not found then,
#      or was found only through a RELATIVE PATH entry (so its path is not
#      absolute), is never looked up on PATH or run later. The harness stops
#      the suite non-zero where it first needs that tool -- the first record
#      for rm/ln, with_fixture's known-hosts snapshot for find (when the real
#      known-hosts directory exists) -- before any summary, and the output
#      names it as "<tool> tool"; for a relative path it also says "not an
#      absolute path". Recording stubs of the tools put first on PATH later
#      record nothing.
#  C5. (M6) A symlink that appears at the agreed results path AFTER the
#      harness's first look and before it links (planted here from the mktemp
#      seam, which runs in between) -- to a regular file, to a directory, or
#      dangling -- stops the suite non-zero with "results file" and "symlink",
#      no summary, and writes through nothing: the target file stays empty,
#      the target directory stays EMPTY (the link to the agreed name must not
#      follow a symlink to a directory), a dangling target is not created.
#  C6. A symlink to a directory planted at the agreed path before the first
#      record of a native (harness.sh-only) suite is refused the same way.
#  C7. (M8) with_fake_runtime's housekeeping (resetting a re-registered tool's
#      call count) never goes through a shell function or a PATH stub named
#      rm: with either in place, re-registering a fake still starts its count
#      over, and the stub/function records nothing.
#  C8. with_fake_runtime stops the suite non-zero, before any later case or
#      summary, when the fake it wrote is not executable after its chmod (a
#      chmod on PATH that exits 0 and changes nothing); the output names
#      "fake <tool>" and says "not executable". chmod stays the PATH seam.
#  C9. A process substitution `<( … )` is a fork too, even where Bash (3.2)
#      leaves BASH_SUBSHELL unchanged in it: one that ends the suite with
#      exit_with_code / finish (with or without unsetting DXE_TEST_RESULTS)
#      never deletes the suite's results file.
#  C10. 200 background jobs recording at once (test_pass/test_fail, and
#      `( it; expect_exit )`) are counted exactly, within the probe bound.
#
# Grading is by this file's own small vocabulary, every probe is a FILE run
# with this file's bash as its own suite process, with its own empty TMPDIR,
# from this file's scratch directory. Safety: every stub only RECORDS (it
# deletes, links, moves and chmods nothing); no probe runs a destructive
# command on any path it did not create inside this file's scratch directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourced for dxe_test_mktemp_dir only; this shell never records a case.
# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# The probes must start as fresh suites, whatever ran this file.
unset DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER DXE_FAKE_RUNTIME_DIR FAKE_TRANSCRIPT

HR_LIB_HELPERS="$SCRIPT_DIR/test_helpers.sh"
HR_LIB_HARNESS="$SCRIPT_DIR/lib/harness.sh"
HR_BASH="${BASH:-bash}"
HR_BOUND=120
HR_ESC="$(printf '\033')"
HR_FAIL_MARK="✗ FAIL"
HR_FAILED_HEADER="Failed cases (from the results file):"
HR_REAL_MKTEMP="$(command -v mktemp)"
HR_REAL_LN="$(command -v ln)"
HR_REAL_RM="$(command -v rm)"

HR_DIR="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir HR_DIR "${TMPDIR:-/tmp}/dxe-harness-round-c.XXXXXX"
trap 'rm -rf "$HR_DIR"' EXIT
mkdir "$HR_DIR/probes" || exit 1
# A home whose real known-hosts tree exists, so with_fixture's snapshot needs find.
mkdir -p "$HR_DIR/home/.local/state/dxe" || exit 1
: > "$HR_DIR/home/.local/state/dxe/known" || exit 1

# --- grading vocabulary (as in the siblings) -------------------------------

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

# hr_body VAR -- reads a probe body from a here-document into VAR.
hr_body() {
    IFS= read -r -d '' "$1" || true
}

# hr_probe NAME LIB BODY -- probe file $HR_DIR/probes/NAME.sh: a suite that
# sources LIB and runs BODY.
hr_probe() {
    {
        printf '#!/bin/bash\nset -uo pipefail\n'
        printf 'source %q\n' "$2"
        printf '%s\n' "$3"
    } > "$HR_DIR/probes/$1.sh" || exit 1
}

# hr_probe_raw NAME BODY -- the same without the top-level source: BODY
# sources the library itself (in a subshell, or after changing PATH).
hr_probe_raw() {
    printf '#!/bin/bash\nset -uo pipefail\n%s\n' "$2" > "$HR_DIR/probes/$1.sh" || exit 1
}

# hr_run_probe NAME [ENV-ARGS...] -- runs probe NAME from $HR_DIR with this
# file's bash, TMPDIR=$HR_TMP (plus `env` arguments), bounded by HR_BOUND
# seconds; sets HR_OUT (stdout+stderr, colour codes stripped) and HR_STATUS.
hr_run_probe() {
    local name="$1"
    shift
    HR_OUT="$(cd "$HR_DIR" && env "$@" TMPDIR="$HR_TMP" perl -e 'alarm shift; exec @ARGV' "$HR_BOUND" "$HR_BASH" "$HR_DIR/probes/$name.sh" 2>&1)" && HR_STATUS=0 || HR_STATUS=$?
    HR_OUT="$(printf '%s\n' "$HR_OUT" | sed "s/${HR_ESC}\[[0-9;]*m//g")"
}

# hr_listing DIR -- every path under DIR, relative, sorted.
hr_listing() {
    (cd -P -- "$1" && find . -mindepth 1 -print) | LC_ALL=C sort
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
only_results_line_is() { [ "$(hr_results_lines)" = "$1" ]; }
last_results_line_is() { [ "$(hr_results_lines | tail -n 1)" = "$1" ]; }
no_results_line() { [ -z "$(hr_results_lines)" ]; }
failed_list_is() { [ "$(hr_failed_list | LC_ALL=C sort)" = "$(printf '%s' "$1" | LC_ALL=C sort)" ]; }
out_contains() {
    case "$HR_OUT" in
        *"$1"*) return 0 ;;
        *) return 1 ;;
    esac
}
out_lacks() { ! out_contains "$1"; }
tmpdir_is_empty() { [ -z "$(hr_listing "$HR_TMP")" ]; }
# No harness-made file anywhere under the probe's TMPDIR (a suite's own
# fixture and fake-runtime directories may remain).
no_harness_files() {
    local listing
    listing="$(hr_listing "$HR_TMP")"
    case "$listing" in
        *dxe-harness-results*|*dxe-harness-out*|*dxe-harness-err*) return 1 ;;
    esac
    return 0
}

# hr_expect_summary STATUS RESULTS FAILED-LIST -- exact exit status, exactly
# one summary line, the failed list (newline-separated labels, "" for none),
# and an empty TMPDIR afterwards.
hr_expect_summary() {
    hr_check "exits $1" status_is "$1"
    hr_check "summary is exactly [$2]" only_results_line_is "$2"
    hr_check "failed-case list is exactly [$(printf '%s' "$3" | tr '\n' ',')]" failed_list_is "$3"
    hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty
}

# hr_expect_stopped -- the fail-closed shape: non-zero, no summary, stopped
# before "@@continued@@".
hr_expect_stopped() {
    hr_check "exits non-zero" status_nonzero
    hr_check "prints no summary" no_results_line
    hr_check "stops before the code after it" out_lacks "@@continued@@"
}

# hr_stubs N TOOL... -- recording stubs named TOOL in $HR_DIR/stubs-N, logging
# to $HR_DIR/log-N (both OUTSIDE the probe's TMPDIR). They record and do
# nothing else. Sets STUBS and STUB_LOG.
STUBS=""
STUB_LOG=""
hr_stubs() {
    local t
    STUBS="$HR_DIR/stubs-$1"
    STUB_LOG="$HR_DIR/log-$1"
    shift
    mkdir "$STUBS" || exit 1
    : > "$STUB_LOG" || exit 1
    for t in "$@"; do
        printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$t" "$STUB_LOG" > "$STUBS/$t" || exit 1
        chmod 0755 "$STUBS/$t" || exit 1
    done
}
log_empty() { [ ! -s "$STUB_LOG" ]; }

# Every probe that uses stubs ends by showing their log, so a failure explains itself.
LOG_TRAP='trap '"'"'printf "@@stub-log\n"; cat "$STUB_LOG"; printf "@@end\n"'"'"' EXIT'

# =========================================================================
# C1 (M1). a harness sourced in a subshell ends there and cleans up
# =========================================================================

hr_case C1-a-helpers-sourced-one-level-down
hr_body body <<'EOP'
( source "$C_LIB"; test_fail "c1a-fail"; test_pass "c1a-pass"; print_summary; exit_with_code )
exit $?
EOP
hr_probe_raw C1a "$body"
hr_run_probe C1a C_LIB="$HR_LIB_HELPERS"
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "c1a-fail"

hr_case C1-b-native-sourced-two-levels-down
hr_body body <<'EOP'
( ( source "$C_LIB"; it "c1b fails"; expect_exit 1 true; it "c1b passes"; expect_exit 0 true; finish ) )
exit $?
EOP
hr_probe_raw C1b "$body"
hr_run_probe C1b C_LIB="$HR_LIB_HARNESS"
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 1 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# C2 (M2). a fork that re-sources the harness and ends itself
# =========================================================================

hr_case C2-a-helpers-forks-resource-then-exit
hr_body body <<'EOP'
test_fail "c2a-parent-fail"
( source "$C_LIB"; exit_with_code ) > /dev/null 2>&1
( source "$C_LIB"; unset DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER; exit_with_code ) > /dev/null 2>&1
c2a_sub="$(source "$C_LIB"; exit_with_code 2>&1)"
test_pass "c2a-after-forks"
print_summary
exit_with_code
EOP
hr_probe C2a "$HR_LIB_HELPERS" "$body"
hr_run_probe C2a C_LIB="$HR_LIB_HELPERS"
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "c2a-parent-fail"

hr_case C2-b-native-forks-resource-then-finish
hr_body body <<'EOP'
it "c2b fails"; expect_exit 1 true
( source "$C_LIB"; finish ) > /dev/null 2>&1 &
wait
( source "$C_LIB"; unset DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER; finish ) > /dev/null 2>&1
it "c2b passes"; expect_exit 0 true
finish
EOP
hr_probe C2b "$HR_LIB_HARNESS" "$body"
hr_run_probe C2b C_LIB="$HR_LIB_HARNESS"
hr_check "exits 1" status_is 1
hr_check "the last summary is exactly [Results: 1 passed, 1 failed, 0 skipped]" last_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# C3 (M7). TMPDIR changed, then a fork re-sources and records first
# =========================================================================

HR_OTHER=""
other_dir_is_empty() { [ -z "$(hr_listing "$HR_OTHER")" ]; }

hr_case C3-a-helpers-tmpdir-changed-fork-resources
HR_OTHER="$HR_DIR/other-c3a"
mkdir "$HR_OTHER" || exit 1
hr_body body <<'EOP'
TMPDIR="$C_OTHER"; export TMPDIR
( source "$C_LIB"; test_fail "c3a-fork-first" )
test_pass "c3a-parent"
print_summary
exit_with_code
EOP
hr_probe C3a "$HR_LIB_HELPERS" "$body"
hr_run_probe C3a C_LIB="$HR_LIB_HELPERS" C_OTHER="$HR_OTHER"
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "c3a-fork-first"
hr_check "leaves nothing in the other directory" other_dir_is_empty

hr_case C3-b-native-with-fixture-fork-resources
hr_body body <<'EOP'
with_fixture
( source "$C_LIB"; it "c3b fork fails"; expect_exit 1 true )
it "c3b parent passes"; expect_exit 0 true
finish
EOP
hr_probe C3b "$HR_LIB_HARNESS" "$body"
hr_run_probe C3b -u XDG_STATE_HOME HOME="$HR_DIR/home" C_LIB="$HR_LIB_HARNESS"
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 1 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "leaves no harness file in its TMPDIR (fixture directories aside)" no_harness_files

# =========================================================================
# C4 (M4). a tool not captured as an absolute path is never used
# =========================================================================

# PATH at source time: an empty directory (no rm, ln or find at all), or a
# directory holding links to the real rm and ln but no find.
mkdir "$HR_DIR/empty-path" "$HR_DIR/no-find" || exit 1
"$HR_REAL_LN" -s "$HR_REAL_RM" "$HR_DIR/no-find/rm" || exit 1
"$HR_REAL_LN" -s "$HR_REAL_LN" "$HR_DIR/no-find/ln" || exit 1

hr_case C4-a-native-rm-ln-find-absent-at-source
hr_stubs c4a rm ln find mv chown
hr_body body <<'EOP'
c_saved_path="$PATH"
PATH="$C_SOURCE_PATH"
source "$C_LIB"
PATH="$C_STUBS:$c_saved_path"
it "c4a should not count"; expect_exit 0 true
finish
echo "@@continued@@"
EOP
hr_probe_raw C4a "$LOG_TRAP
$body"
hr_run_probe C4a C_LIB="$HR_LIB_HARNESS" C_SOURCE_PATH="$HR_DIR/empty-path" C_STUBS="$STUBS" STUB_LOG="$STUB_LOG"
hr_expect_stopped
c4a_names_tool() { out_contains "ln tool" || out_contains "rm tool"; }
hr_check "names the missing tool ('ln tool' or 'rm tool')" c4a_names_tool
hr_check "no stub on PATH ran" log_empty

hr_case C4-b-native-find-absent-at-source
hr_stubs c4b rm ln find mv chown
hr_body body <<'EOP'
c_saved_path="$PATH"
PATH="$C_SOURCE_PATH"
source "$C_LIB"
PATH="$C_STUBS:$c_saved_path"
with_fixture
it "c4b should not count"; expect_exit 0 true
finish
echo "@@continued@@"
EOP
hr_probe_raw C4b "$LOG_TRAP
$body"
hr_run_probe C4b -u XDG_STATE_HOME HOME="$HR_DIR/home" C_LIB="$HR_LIB_HARNESS" C_SOURCE_PATH="$HR_DIR/no-find" C_STUBS="$STUBS" STUB_LOG="$STUB_LOG"
hr_expect_stopped
hr_check "names the missing tool ('find tool')" out_contains "find tool"
hr_check "no stub on PATH ran" log_empty

# c4_relative TOOL -- TOOL is found at source time only through the relative
# PATH entry rel-TOOL (a recording stub, relative to the probe's cwd); after
# sourcing, PATH is the real one again.
c4_relative() {
    local tool="$1"
    hr_case "C4-rel-$tool-captured-relative"
    hr_stubs "rel-$tool"
    mkdir "$HR_DIR/rel-$tool" || exit 1
    printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$tool" "$STUB_LOG" > "$HR_DIR/rel-$tool/$tool" || exit 1
    chmod 0755 "$HR_DIR/rel-$tool/$tool" || exit 1
    hr_body body <<'EOP'
c_saved_path="$PATH"
PATH="$C_REL:$PATH"
source "$C_LIB"
PATH="$c_saved_path"
with_fixture
it "c4 relative should not count"; expect_exit 0 true
finish
echo "@@continued@@"
EOP
    hr_probe_raw "C4rel$tool" "$LOG_TRAP
$body"
    hr_run_probe "C4rel$tool" -u XDG_STATE_HOME HOME="$HR_DIR/home" C_LIB="$HR_LIB_HARNESS" C_REL="rel-$tool" STUB_LOG="$STUB_LOG"
    hr_expect_stopped
    hr_check "names the tool ('$tool tool')" out_contains "$tool tool"
    hr_check "says it is not an absolute path" out_contains "not an absolute path"
    hr_check "the relative $tool never ran" log_empty
}
c4_relative rm
c4_relative ln
c4_relative find

# =========================================================================
# C5 (M6). a symlink appearing at the agreed path between look and link
# =========================================================================

# The mktemp seam plants the symlink once, when the harness asks mktemp for
# its results file -- after the harness's first look at the agreed path.
mkdir "$HR_DIR/plant-bin" || exit 1
cat > "$HR_DIR/plant-bin/mktemp" <<EOF || exit 1
#!/bin/bash
case "\$*" in
    *dxe-harness-results.XXXXXX*)
        if [ -n "\${C_AGREED:-}" ] && [ ! -e "\$C_PLANTED" ]; then
            : > "\$C_PLANTED" || exit 97
            "$HR_REAL_LN" -s "\$C_TARGET" "\$C_AGREED" || exit 97
        fi
        ;;
esac
exec "$HR_REAL_MKTEMP" "\$@"
EOF
chmod 0755 "$HR_DIR/plant-bin/mktemp" || exit 1

# c5_case NAME LIB KIND -- KIND: file | dir | dangling.
c5_case() {
    local name="$1" lib="$2" kind="$3" target="$HR_DIR/c5-target-$1"
    hr_case "C5-$name"
    case "$kind" in
        file) : > "$target" || exit 1 ;;
        dir) mkdir "$target" || exit 1 ;;
        dangling) : ;;
    esac
    hr_body body <<'EOP'
PATH="$C_PLANT_BIN:$PATH"
C_AGREED="$TMPDIR/dxe-harness-results.$DXE_HARNESS_RES_TOKEN"; export C_AGREED
test_pass "c5-should-not-count"
print_summary
exit_with_code
echo "@@continued@@"
EOP
    if [ "$lib" = native ]; then
        body="${body//test_pass \"c5-should-not-count\"/it \"c5-should-not-count\"; expect_exit 0 true}"
        body="${body//print_summary/finish}"
        lib="$HR_LIB_HARNESS"
    else
        lib="$HR_LIB_HELPERS"
    fi
    hr_probe "C5$name" "$lib" "$body"
    hr_run_probe "C5$name" C_PLANT_BIN="$HR_DIR/plant-bin" C_PLANTED="$HR_DIR/c5-planted-$name" C_TARGET="$target"
    c5_planted() { [ -e "$HR_DIR/c5-planted-$name" ]; }
    hr_check "the seam planted the link (case is live)" c5_planted
    hr_expect_stopped
    hr_check "names the results file" out_contains "results file"
    hr_check "says it is a symlink" out_contains "symlink"
    case "$kind" in
        file) c5_untouched() { [ -f "$target" ] && [ ! -s "$target" ]; } ;;
        dir) c5_untouched() { [ -d "$target" ] && [ -z "$(hr_listing "$target")" ]; } ;;
        dangling) c5_untouched() { [ ! -e "$target" ] && [ ! -L "$target" ]; } ;;
    esac
    hr_check "wrote through nothing (the $kind target is untouched)" c5_untouched
}
c5_case native-file native file
c5_case native-dir native dir
c5_case native-dangling native dangling
c5_case helpers-dir helpers dir

# =========================================================================
# C6. a native suite: a symlink to a directory at the agreed path
# =========================================================================

hr_case C6-native-dir-at-agreed-path
c6_target="$HR_DIR/c6-target"
mkdir "$c6_target" || exit 1
hr_body body <<'EOP'
ln -s "$C_TARGET" "$TMPDIR/dxe-harness-results.$DXE_HARNESS_RES_TOKEN"
it "c6-should-not-count"; expect_exit 0 true
finish
echo "@@continued@@"
EOP
hr_probe C6 "$HR_LIB_HARNESS" "$body"
hr_run_probe C6 C_TARGET="$c6_target"
hr_expect_stopped
hr_check "names the results file" out_contains "results file"
hr_check "says it is a symlink" out_contains "symlink"
c6_untouched() { [ -d "$c6_target" ] && [ -z "$(hr_listing "$c6_target")" ]; }
hr_check "wrote through nothing (the directory stays empty)" c6_untouched

# =========================================================================
# C7 (M8). with_fake_runtime's own rm bypasses functions and PATH stubs
# =========================================================================

hr_case C7-a-native-rm-function
hr_stubs c7a
hr_body body <<'EOP'
rm() { echo "rm-function $*" >> "$STUB_LOG"; }
with_fake_runtime docker
docker first-call
with_fake_runtime docker
fake_fail_nth docker 1 7
it "c7a a re-registered fake counts from 1 again"; expect_exit 7 docker second-call
it "c7a its next call is call 2"; expect_exit 0 docker third-call
finish
EOP
hr_probe C7a "$HR_LIB_HARNESS" "$LOG_TRAP
$body"
hr_run_probe C7a STUB_LOG="$STUB_LOG"
hr_check "exits 0" status_is 0
hr_check "summary is exactly [Results: 2 passed, 0 failed, 0 skipped]" only_results_line_is "Results: 2 passed, 0 failed, 0 skipped"
hr_check "the rm function recorded nothing" log_empty
hr_check "leaves no harness file in its TMPDIR" no_harness_files

hr_case C7-b-native-rm-path-stub
hr_stubs c7b rm find ln mv chown
hr_body body <<'EOP'
PATH="$C_STUBS:$PATH"
with_fake_runtime docker
docker first-call
PATH="$C_STUBS:$PATH"
with_fake_runtime docker
fake_fail_nth docker 1 7
it "c7b a re-registered fake counts from 1 again"; expect_exit 7 docker second-call
it "c7b its next call is call 2"; expect_exit 0 docker third-call
finish
EOP
hr_probe C7b "$HR_LIB_HARNESS" "$LOG_TRAP
$body"
hr_run_probe C7b C_STUBS="$STUBS" STUB_LOG="$STUB_LOG"
hr_check "exits 0" status_is 0
hr_check "summary is exactly [Results: 2 passed, 0 failed, 0 skipped]" only_results_line_is "Results: 2 passed, 0 failed, 0 skipped"
hr_check "no stub on PATH ran" log_empty
hr_check "leaves no harness file in its TMPDIR" no_harness_files

# =========================================================================
# C8. a fake that is not executable after chmod stops the suite
# =========================================================================

# A chmod that records its call, exits 0 and changes nothing.
hr_stubs c8 chmod

hr_case C8-a-native-docker
: > "$STUB_LOG"
hr_body body <<'EOP'
PATH="$C_STUBS:$PATH"
with_fake_runtime docker
it "c8a should not count"; expect_exit 0 true
finish
echo "@@continued@@"
EOP
hr_probe C8a "$HR_LIB_HARNESS" "$body"
hr_run_probe C8a C_STUBS="$STUBS"
c8_chmod_ran() { [ -s "$STUB_LOG" ]; }
hr_check "the chmod on PATH was the one called (case is live)" c8_chmod_ran
hr_expect_stopped
hr_check "names the fake" out_contains "fake docker"
hr_check "says it is not executable" out_contains "not executable"

hr_case C8-b-helpers-ssh
: > "$STUB_LOG"
hr_body body <<'EOP'
PATH="$C_STUBS:$PATH"
with_fake_runtime ssh
test_pass "c8b should not count"
print_summary
exit_with_code
echo "@@continued@@"
EOP
hr_probe C8b "$HR_LIB_HELPERS" "$body"
hr_run_probe C8b C_STUBS="$STUBS"
hr_check "the chmod on PATH was the one called (case is live)" c8_chmod_ran
hr_expect_stopped
hr_check "names the fake" out_contains "fake ssh"
hr_check "says it is not executable" out_contains "not executable"
hr_check "prints no case result line" out_lacks "c8b should not count"

# =========================================================================
# C9. a process substitution that ends the suite
# =========================================================================

hr_case C9-a-helpers-process-substitution
hr_body body <<'EOP'
test_fail "c9a-parent-fail"
cat <(exit_with_code 2>&1) > /dev/null
cat <(unset DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER; exit_with_code 2>&1) > /dev/null
while IFS= read -r c9a_line; do :; done < <(exit_with_code 2>&1)
test_pass "c9a-after"
print_summary
exit_with_code
EOP
hr_probe C9a "$HR_LIB_HELPERS" "$body"
hr_run_probe C9a
hr_expect_summary 1 "Results: 1 passed, 1 failed, 0 skipped" "c9a-parent-fail"

hr_case C9-b-native-process-substitution
hr_body body <<'EOP'
it "c9b fails"; expect_exit 1 true
cat <(finish 2>&1) > /dev/null
it "c9b passes"; expect_exit 0 true
finish
EOP
hr_probe C9b "$HR_LIB_HARNESS" "$body"
hr_run_probe C9b
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 1 passed, 1 failed, 0 skipped]" only_results_line_is "Results: 1 passed, 1 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

# =========================================================================
# C10. 200 background jobs recording at once
# =========================================================================

hr_case C10-a-helpers-200-jobs
hr_body body <<'EOP'
i=0
while [ "$i" -lt 200 ]; do
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
hr_probe C10a "$HR_LIB_HELPERS" "$body"
hr_run_probe C10a
c10_expected="$(i=0; while [ "$i" -lt 200 ]; do i=$((i + 1)); [ $((i % 5)) -eq 0 ] && printf 'race-%s\n' "$i"; done)"
hr_expect_summary 1 "Results: 160 passed, 40 failed, 0 skipped" "$c10_expected"

hr_case C10-b-native-200-jobs
hr_body body <<'EOP'
i=0
while [ "$i" -lt 200 ]; do
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
hr_probe C10b "$HR_LIB_HARNESS" "$body"
hr_run_probe C10b
hr_check "exits 1" status_is 1
hr_check "summary is exactly [Results: 160 passed, 40 failed, 0 skipped]" only_results_line_is "Results: 160 passed, 40 failed, 0 skipped"
hr_check "leaves nothing in its TMPDIR" tmpdir_is_empty

echo ""
echo "=============================="
echo "Results: $hr_passes passed, $hr_failures failed, 0 skipped"
echo "=============================="
[ "$hr_failures" -eq 0 ]
