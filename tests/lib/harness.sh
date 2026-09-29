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

# --- Shared runtime fakes (Fable D5, E3) --------------------------------
#
# tests/lib/fake-tools.sh already covers the DX guest ssh boundary and the
# docker-ssh management-plane ssh boundary; what was missing was a shared
# `docker`/`container`/`ssh` fake ANY fixture could ask for without
# re-writing a pass-through body and a PATH ritual per suite (D5's evidence:
# test_docker_runtime_adapter.sh alone carries 105 hand-written docker
# bodies and pins its own PATH 126 times). `with_fake_runtime` is that
# shared fake: one private directory, reused across every tool a fixture
# asks for, on a SINGLE PATH convention every fixture can now share instead
# of inventing its own.
#
# Lazy, process-private state (mirrors _dxe_harness_results_file/
# DXE_TEST_RESULTS): nothing here runs at source time, only the first time
# with_fake_runtime is actually called.
_dxe_harness_fake_runtime_dir() {
    if [ -z "${DXE_FAKE_RUNTIME_DIR:-}" ]; then
        local dir
        dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-fake-runtime.XXXXXX")"
        DXE_FAKE_RUNTIME_DIR="$dir"
        export DXE_FAKE_RUNTIME_DIR
    fi
}

# $FAKE_TRANSCRIPT: one shared, append-only log for every tool this process
# fakes (docker AND ssh AND container all land in the SAME file), so a
# fixture can assert ordering across tools, not just per-tool.
_dxe_harness_fake_transcript_file() {
    if [ -z "${FAKE_TRANSCRIPT:-}" ]; then
        local file
        file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-fake-transcript.XXXXXX")"
        FAKE_TRANSCRIPT="$file"
        export FAKE_TRANSCRIPT
    fi
}

# with_fake_runtime docker|container|ssh
#
# Writes a fake executable named $1 into the shared private directory
# (creating it, and $FAKE_TRANSCRIPT, on first use), then pins
# PATH="$DXE_FAKE_RUNTIME_DIR:$(dirname "$(command -v bash)"):/usr/bin:/bin"
# in the CALLING shell -- the single convention this codebase's fixtures
# should now share. Naming bash's own directory explicitly (rather than
# relying on /bin or /usr/bin already containing it) is what lets a fake
# written with `#!/usr/bin/env bash` (E3) still resolve bash on a host
# without /bin/bash, e.g. NixOS (Fable E3's whole point -- see the (p) case
# in tests/test_harness.sh, which proves this under a PATH containing
# neither /bin nor /usr/bin at all).
#
# Calling this again for a second/third tool in the same process reuses the
# SAME directory (so docker+ssh+container fakes coexist on one PATH) but
# resets that ONE tool's own call count, fail plan and scripted responses --
# re-registering a tool's fake starts that boundary over, without touching
# any other tool's state or the shared transcript (which is cumulative for
# the whole fixture by design).
#
# Each invocation of the fake appends one line to $FAKE_TRANSCRIPT: its
# whole argv, each argument `%q`-quoted and space-joined (so
# `expect_transcript` can match it as an ERE without caring how the
# original call happened to quote anything). By default a call exits 0
# with no output; fake_fail_nth and fake_respond script anything else.
with_fake_runtime() {
    local tool="$1"
    _dxe_harness_fake_runtime_dir
    _dxe_harness_fake_transcript_file
    rm -f "$DXE_FAKE_RUNTIME_DIR/.count-$tool" "$DXE_FAKE_RUNTIME_DIR/.failplan-$tool" "$DXE_FAKE_RUNTIME_DIR/.responses-$tool"
    : > "$DXE_FAKE_RUNTIME_DIR/.failplan-$tool"
    : > "$DXE_FAKE_RUNTIME_DIR/.responses-$tool"
    cat > "$DXE_FAKE_RUNTIME_DIR/$tool" <<FAKE_EOF
#!/usr/bin/env bash
dxe_fake_transcript="$FAKE_TRANSCRIPT"
dxe_fake_count_file="$DXE_FAKE_RUNTIME_DIR/.count-$tool"
dxe_fake_failplan="$DXE_FAKE_RUNTIME_DIR/.failplan-$tool"
dxe_fake_responses="$DXE_FAKE_RUNTIME_DIR/.responses-$tool"

dxe_fake_line=""
for dxe_fake_arg in "\$@"; do
    dxe_fake_line="\$dxe_fake_line\$(printf '%q ' "\$dxe_fake_arg")"
done
printf '%s\n' "\$dxe_fake_line" >> "\$dxe_fake_transcript"

dxe_fake_n=0
[ -s "\$dxe_fake_count_file" ] && dxe_fake_n="\$(cat "\$dxe_fake_count_file")"
dxe_fake_n=\$((dxe_fake_n + 1))
printf '%s\n' "\$dxe_fake_n" > "\$dxe_fake_count_file"

if [ -s "\$dxe_fake_failplan" ]; then
    dxe_fake_code="\$(awk -v n="\$dxe_fake_n" '\$1 == n { print \$2; exit }' "\$dxe_fake_failplan")"
    if [ -n "\$dxe_fake_code" ]; then
        exit "\$dxe_fake_code"
    fi
fi

if [ -s "\$dxe_fake_responses" ]; then
    dxe_fake_joined="\$*"
    while IFS=\$'\t' read -r dxe_fake_key dxe_fake_out; do
        case "\$dxe_fake_joined" in
            "\$dxe_fake_key"*)
                printf '%s\n' "\$dxe_fake_out"
                exit 0
                ;;
        esac
    done < "\$dxe_fake_responses"
fi
exit 0
FAKE_EOF
    chmod 0755 "$DXE_FAKE_RUNTIME_DIR/$tool"
    PATH="$DXE_FAKE_RUNTIME_DIR:$(dirname "$(command -v bash)"):/usr/bin:/bin"
}

# fake_fail_nth TOOL N CODE -- makes the Nth call to TOOL's fake (TOOL must
# already have one from with_fake_runtime) exit CODE; every other call
# exits 0 (or whatever fake_respond separately scripted for it -- fail_nth
# always wins over a scripted response on a matching call number, the same
# way a real boundary failing pre-empts whatever it would otherwise have
# returned).
fake_fail_nth() {
    local tool="$1" n="$2" code="$3"
    _dxe_harness_fake_runtime_dir
    printf '%s\t%s\n' "$n" "$code" >> "$DXE_FAKE_RUNTIME_DIR/.failplan-$tool"
}

# fake_respond TOOL 'match prefix' 'output' -- scripts stdout for any call
# to TOOL's fake whose whole argv, space-joined, STARTS WITH 'match prefix'.
# This is the shape the ~20 `"$1 $2") echo "27.3.1" ;;` arms in
# test_docker_runtime_adapter.sh already hand-roll one case statement at a
# time; fake_respond docker 'version --format' '27.3.1' is the same
# contract as one line instead of a case arm, so those bodies can collapse
# onto this later (not migrated by this change). First-registered matching
# prefix wins. TOOL must already have a fake from with_fake_runtime.
fake_respond() {
    local tool="$1" match="$2" output="$3"
    _dxe_harness_fake_runtime_dir
    printf '%s\t%s\n' "$match" "$output" >> "$DXE_FAKE_RUNTIME_DIR/.responses-$tool"
}

# expect_transcript PATTERN -- asserts some line of $FAKE_TRANSCRIPT
# matches PATTERN as an ERE (grep -E), expect_stdout's shape applied to the
# fakes' shared transcript file instead of one command's captured stdout.
expect_transcript() {
    local pattern="$1"
    local label="${DXE_HARNESS_LABEL:-expect_transcript $pattern}"
    _dxe_harness_fake_transcript_file
    if [ -s "$FAKE_TRANSCRIPT" ] && grep -Eq -- "$pattern" "$FAKE_TRANSCRIPT"; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected some transcript line to match (ERE): $pattern"
        echo "  transcript:"
        sed 's/^/    /' "$FAKE_TRANSCRIPT" 2>/dev/null
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
